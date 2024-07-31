-- Alma Borrowing Request Sender, version 1.24 (December 25, 2023)
-- This Server Addon was developed by Bill Jones (SUNY Geneseo), Tim Jackson (SUNY Libraries Shared Services), and Angela Persico (University at Albany)
-- The purpose of this Addon is to send Borrowing requests from ILLiad to Alma, and Hold requests for owned items
-- The Addon monitors RequestType: Loan in a configurable ILLiad queue for ProcessType: Borrowing
-- For usernames, the Addon allows staff to select which field in the Users table to use. Potential options include Username, SSN, and email
-- The Addon uses an Alma SRU Lookup to determine availability and to gather item information
-- The Addon uses the Bibs API in order to lookup item process_type for unavailable items to determine if MISSING, IN BINDERY, in ILL, or another process_type
-- The Addon uses the Users API 'Retrieve user loans' call to analyze active requests to sift out duplicate ILL requests
-- The Addon sends a Hold request to Alma using the Users API 'Create user request' call
-- The Addon sends an Borrowing request to Alma using the Users API 'Create user request for resource sharing' call
-- The Addon uses a file called error_routing.txt to route specific API numerical errors to specific ILLiad queues
-- The Addon uses a file called sublibraries.txt to crosswalk between the ILLiad user NVTGC code (Example: ILL) and Alma Pickup Location code (Example: GENMN)
-- The Addon uses a file called process_type_router.txt to route specific process_type values (like MISSING, or IN BINDERY, or RESERVES) to specific queues
-- The Addon uses a file called excluded_locations.txt to make specific shelving locations unavailable for Hold requests 



local Settings = {};
Settings.Alma_Base_URL = GetSetting("Alma_Base_URL");
Settings.Alma_Users_API_Key = GetSetting("Alma_Users_API_Key");
Settings.Alma_Bibs_API_Key = GetSetting("Alma_Bibs_API_Key");
Settings.ItemSearchQueue = GetSetting("ItemSearchQueue");
Settings.ItemSuccessQueue = GetSetting("ItemSuccessQueue");
Settings.ItemFailQueue = GetSetting("ItemFailQueue");
Settings.ItemSuccessHoldRequestQueue = GetSetting("ItemSuccessHoldRequestQueue");
Settings.ItemFailHoldRequestQueue = GetSetting("ItemFailHoldRequestQueue");
Settings.Alma_Institution_Code = GetSetting("Alma_Institution_Code");
Settings.FieldtoUseForUserNameFromUsersTable = GetSetting("FieldtoUseForUserNameFromUsersTable");
Settings.Full_Alma_URL = GetSetting("Full_Alma_URL");
Settings.EnableSendingBorrowingRequests = GetSetting("EnableSendingBorrowingRequests");
Settings.EnableSendingHoldRequests = GetSetting("EnableSendingHoldRequests");
Settings.ElectronicItemSuccessQueue = GetSetting("ElectronicItemSuccessQueue");
Settings.EnableSendingHoldRequests = GetSetting("EnableSendingHoldRequests");
Settings.ILLiadFieldforElectronicItemURL = GetSetting("ILLiadFieldforElectronicItemURL");
Settings.NoISBNandNoOCLCNumberReviewQueue = GetSetting("NoISBNandNoOCLCNumberReviewQueue");
Settings.ElectronicItemReviewQueue = GetSetting("ElectronicItemReviewQueue");
Settings.ItemInExcludedLocationNeedsReviewQueue = GetSetting("ItemInExcludedLocationNeedsReviewQueue");
Settings.AddonWorkerName = GetSetting("AddonWorkerName");
Settings.PreferElectronicOverPrintForHoldRequests = GetSetting("PreferElectronicOverPrintForHoldRequests");

local isCurrentlyProcessing = false;
local client = nil;

-- Assembly Loading and Type Importation
luanet.load_assembly("System");
local Types = {};
Types["WebClient"] = luanet.import_type("System.Net.WebClient");
Types["System.IO.StreamReader"] = luanet.import_type("System.IO.StreamReader");
Types["System.Type"] = luanet.import_type("System.Type");


function Init()
	LogDebug("Initializing ALMA BORROWING REQUEST SENDER Server Addon");
	RegisterSystemEventHandler("SystemTimerElapsed", "TimerElapsed");
end

function TimerElapsed(eventArgs)
	LogDebug("Processing ALMA BORROWING REQUEST SENDER Items");
	if not isCurrentlyProcessing then
		isCurrentlyProcessing = true;

		-- Process Items
		local success, err = pcall(ProcessItems);
		if not success then
			LogDebug("There was a fatal error processing the items.")
			LogDebug("Error: " .. err);
		end
		isCurrentlyProcessing = false;
	else
		LogDebug("Still processing ALMA BORROWING REQUEST SENDER Items");
	end
end

function ProcessItems()
	if Settings.ItemSearchQueue == "" then
		LogDebug("The configuration value for ItemSearchQueue has not been set in the config.xml file.  Stopping Addon.");
	end
	if Settings.ItemSearchQueue ~= "" then
		ProcessDataContexts("TransactionStatus", Settings.ItemSearchQueue, "HandleContextProcessing");
	end
end


function cleanup_field(title)
 
-- " = &quot;
-- ' = &apos;
-- < = &lt;
-- > = &gt;
-- & = &amp;

local cleaned_string = title;

cleaned_string = cleaned_string:gsub('&', '&amp;'):gsub('"', '&quot;'):gsub("'", '&apos;'):gsub('<', '&lt;'):gsub('>', '&gt;'); 

return cleaned_string;
end

function validate_isbn()
LogDebug("Initializing ISBN Validator.");

local isbn = GetFieldValue("Transaction", "ISSN");

if isbn == "" or isbn == nil then
LogDebug("ISBN Validator > There is no ISBN available.  Skipping ISBN Validator.");
return true
end

local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);

local is_13long = false;
local is_10long = false;
 
isbn = isbn:gsub('-', '');
    
	-- check if 10 digits long
	if isbn:match('^%d%d%d%d%d%d%d%d%d[%dX]$') then
	LogDebug("ISBN Validator > The ISBN is 10 Digits long.");
      is_10long = true;
    end
	
	-- check if 13 digits long
	if isbn:match('^%d%d%d%d%d%d%d%d%d%d%d%d[%dX]$') then
	LogDebug("ISBN Validator > The ISBN is 13 Digits long.");
      is_13long = true;
    end
	
	if not is_10long and not is_13long then
	LogDebug("ISBN Validator > The ISBN is not 10 Digits or 13 Digits long.");
	ExecuteCommand("AddNote",{transactionNumber, "ISBN Validator > The ISBN is not 10 Digits or 13 Digits long."});
	return false
	end
	
	-- if 10 digits long, validate the number  
	-- Multiply each of the first 9 digits by a number in the descending sequence from 10 to 2, and sum the results. Divide the sum by 11. The remainder should be 0.
	if is_10long and not is_13long then
		local sum = 0;
		local sum_string = "";
		for i = 1, 10 do
			sum = sum + (11 - i) * (tonumber(isbn:sub(i, i)) or 10);
			sum_string = sum_string .. tostring((11 - i) * (tonumber(isbn:sub(i, i)) or 10)) .. "+";
		end
		
		local remainder = sum % 11;
		
		if remainder == 0 then
		LogDebug("ISBN Validator > The 10ISBN sum is: " .. sum_string:sub(1, -2) .. "=" .. sum .. ". The remainder when " .. sum .. "/11 = " .. remainder);		
		LogDebug("ISBN Validator > The 10 digit ISBN: " .. isbn .. " is Valid.");
		return true
		end
		if remainder ~= 0 then
		LogDebug("ISBN Validator > The 10ISBN sum is: " .. sum_string:sub(1, -2) .. "=" .. sum .. ". The remainder when " .. sum .. "/11 = " .. remainder);		
		LogDebug("ISBN Validator > The 10 digit ISBN: " .. isbn .. " is Not Valid.");
		ExecuteCommand("AddNote",{transactionNumber, "ISBN Validator > The 10 digit ISBN: " .. isbn .. " is Not Valid."});
		return false
		end	
	end
	
	-- if 13 digits long, validate the number
	if is_13long then
	
		--Multiply each of digits by 1 or 3, alternating as you move from left to right, and sum the results.
		--Divide the sum by 10.  The remainder should be 0
		
		local aa = isbn:sub(1, 1);
		local bb = isbn:sub(2, 2) * 3;
		local cc = isbn:sub(3, 3);
		local dd = isbn:sub(4, 4) * 3;
		local ee = isbn:sub(5, 5);
		local ff = isbn:sub(6, 6) * 3;
		local gg = isbn:sub(7, 7);
		local hh = isbn:sub(8, 8) * 3;
		local ii = isbn:sub(9, 9);
		local jj = isbn:sub(10, 10) * 3;
		local kk = isbn:sub(11, 11);
		local mm = isbn:sub(12, 12) * 3;
		local lastdigit = isbn:sub(13, 13);
		
		if lastdigit == "x" or lastdigit == "X" then
			lastdigit = 10;
		end
			
		local sum = aa + bb + cc + dd + ee + ff + gg + hh + ii + jj + kk + mm + lastdigit;
		local remainder = sum % 10;
		
		LogDebug("ISBN Validator > The 13ISBN sum is: " .. tostring(aa) .. "+" .. tostring(bb) .. "+" .. tostring(cc) .. "+" .. tostring(dd) .. "+" .. tostring(ee) .. "+" .. tostring(ff) .. "+" .. tostring(gg) .. "+" .. tostring(hh) .. "+" .. tostring(ii) .. "+" .. tostring(jj) .. "+" .. tostring(kk) .. "+" .. tostring(mm) .. "+" .. tostring(lastdigit) .. "=" .. tostring(sum) .. ". The remainder when " .. sum .. "/10 = " .. remainder);
		
		if remainder == 0 then
			LogDebug("ISBN Validator > The 13 digit ISBN: " .. isbn .. " is valid!");
			return true
		end
		if remainder ~= 0 then
			LogDebug("ISBN Validator > The 13 digit ISBN: " .. isbn .. " is NOT VALID!!");
			ExecuteCommand("AddNote",{transactionNumber, "ISBN Validator > The 13 digit ISBN: " .. isbn .. " is NOT VALID!!"});
			return false
		end	
	end
end


function myerrorhandler2( err )

-- This is the error handler for the Borrowing Request Sender

	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);

   --LogDebug("ALMA BORROWING REQUEST SENDER build_hold_request ERROR");
   
	if err ~= nil then
	--if err.InnerException ~= nil then
		--if (IsType(err, "LuaInterface.LuaScriptException")) and (err.InnerException ~= nil) and (IsType(err.InnerException, "System.Net.WebException")) then
			LogDebug('HTTP Error: ' .. err.InnerException.Message);
			local responseStream = err.InnerException.Response:GetResponseStream();
			local reader = Types["System.IO.StreamReader"](responseStream);
			local responseText = reader:ReadToEnd();
			reader:Close();
			--LogDebug(responseText);
			local errorCode = responseText:match('errorCode>(.-)<'):gsub('(.-)>', '');
			local errorMessage = responseText:match('errorMessage>(.-)<'):gsub('(.-)>', '');
		    LogDebug("Found ALMA errorCode from API for Borrowing Request: " .. errorCode .. ": " .. errorMessage);
		
			LogDebug("There was an error executing the ALMA BORROWING REQUEST SENDER build_request function.");
			if errorCode == '401873' then
			ExecuteCommand("AddNote",{transactionNumber, "Found ALMA Users API errorCode: 401873: Patron has duplicate Borrowing Request in Alma"});
			ExecuteCommand("Route",{transactionNumber, Settings.ItemFailQueue});
			else
			
			local error_routing_list = assert(io.open(AddonInfo.Directory .. "\\error_routing.txt", "r"));
			local line_concatenator = "";
			local first_split = "";
			local second_split = "";
			local templine = nil;
				if error_routing_list ~= nil then
					for line in error_routing_list:lines() do
					line_concatenator = line_concatenator .. " " .. line;
						if string.find(line, errorCode) ~= nil then
							first_split,second_split = line:match("(.+),(.+)");
							Alma_error_code = first_split;
							ILLiad_routing_queue = second_split;
				
							LogDebug("The Alma error code for routing is: " .. Alma_error_code);
							LogDebug("The transaction with the Alma error is being routed to: " .. second_split);
							ExecuteCommand("Route",{transactionNumber, second_split});
							break;
						end

					end
					if string.find(line_concatenator, errorCode) == nil then
						ExecuteCommand("AddNote",{transactionNumber, "Found ALMA Users API errorCode: " .. errorCode .. ": " .. errorMessage});
						ExecuteCommand("Route",{transactionNumber, Settings.ItemFailQueue});
						SaveDataSource("Transaction");
					end
				error_routing_list:close();
				end
			end
	end
end

function myerrorhandler( err )

-- This is the error handler for Borrowing HOLD Request Sender
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);

   --LogDebug("ALMA BORROWING REQUEST SENDER build_request ERROR");
   
	if err ~= nil then
	--if err.InnerException ~= nil then
		LogDebug('HTTP Error: ' .. err.InnerException.Message);
			local responseStream = err.InnerException.Response:GetResponseStream();
			local reader = Types["System.IO.StreamReader"](responseStream);
			local responseText = reader:ReadToEnd();
			reader:Close();
			--LogDebug(responseText);
			local errorCode = responseText:match('errorCode>(.-)<'):gsub('(.-)>', '');
			local errorMessage = responseText:match('errorMessage>(.-)<'):gsub('(.-)>', '');
		    LogDebug("Found ALMA errorCode: " .. errorCode .. ": " .. errorMessage);
		
			LogDebug("There was an error executing the ALMA BORROWING REQUEST SENDER build_hold_request function.");
			ExecuteCommand("AddNote",{transactionNumber, "Found ALMA Users HOLD Request API errorCode: " .. errorCode .. ": " .. errorMessage});
			SaveDataSource("Transaction");
			--ExecuteCommand("AddNote",{transactionNumber, responseText});
						
			if errorCode ~= nil then
			
			if errorCode == '401136' then
			ExecuteCommand("Route",{transactionNumber, Settings.ItemFailHoldRequestQueue});
			
			else
						
			local error_routing_list = assert(io.open(AddonInfo.Directory .. "\\error_routing.txt", "r"));
			local line_concatenator = "";
			local first_split = "";
			local second_split = "";
			local templine = nil;
				if error_routing_list ~= nil then
					for line in error_routing_list:lines() do
					line_concatenator = line_concatenator .. " " .. line;
						if string.find(line, errorCode) ~= nil then
							first_split,second_split = line:match("(.+),(.+)");
							Alma_error_code = first_split;
							ILLiad_routing_queue = second_split;
				
							LogDebug("The Alma error code for routing is: " .. Alma_error_code);
							LogDebug("The transaction with the Alma error is being routed to: " .. second_split);
							ExecuteCommand("Route",{transactionNumber, second_split});
							break;
						end

					end
					if string.find(line_concatenator, errorCode) == nil then
					
					local messageSent = false;
					local response;
					if Settings.EnableSendingBorrowingRequests == true then
					messageSent, response = pcall(build_request);
			
						if (messageSent == false) then
							LogDebug('There was an error in the Alma_API from the build_request function.  Sending to Error Handler.');
							return myerrorhandler2(response);		
						else		
						end
					end
					if Settings.EnableSendingBorrowingRequests == false then
						ExecuteCommand("Route",{transactionNumber, Settings.ItemFailHoldRequestQueue});
					end
					
					end
				error_routing_list:close();
				end
			end
			
		end
	--end
	--if (IsType(err, "System.Exception")) then
		--return nil, 'Unable to handle error. ' .. err.Message;
	--else
		--return nil, 'Unable to handle error.';
	--end
	end
	
end

function rerun_checker()
    local has_it_run = false;
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT TransactionNumber FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND NOTE = 'The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " ran on this transaction.'";
	connection:Connect();
	local rerun_status = connection:ExecuteScalar();
	connection:Disconnect();
	if rerun_status == transactionNumber then
		LogDebug('The ALMA BORROWING REQUEST SENDER already ran on transaction ' .. transactionNumber .. '. Now Stopping Addon.');
		if Settings.ItemFailHoldRequestQueue ~= "" then
			ExecuteCommand("Route",{transactionNumber, Settings.ItemFailHoldRequestQueue});
			ExecuteCommand("AddNote",{transactionNumber, "ERROR: The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " already ran on this transaction and it has been sitting in the " .. Settings.ItemSearchQueue .. " processing queue. The TN is being routed to " .. Settings.ItemFailHoldRequestQueue .. ". Please remove the note that says 'The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " ran on this transaction.' and re-route the TN to the " .. Settings.ItemSearchQueue .. " queue in order to reprocess the TN."});
		end
		if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
			ExecuteCommand("Route",{transactionNumber, Settings.ItemFailQueue});
			ExecuteCommand("AddNote",{transactionNumber, "ERROR: The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " already ran on this transaction and it has been sitting in the " .. Settings.ItemSearchQueue .. " processing queue. The TN is being routed to " .. Settings.ItemFailQueue .. ". Please remove the note that says 'The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " ran on this transaction.' and re-route the TN to the " .. Settings.ItemSearchQueue .. " queue in order to reprocess the TN."});
		end	
		
		has_it_run = true;	
	end
	return has_it_run;
end


function usernote_appender()
    local usernote_append = "";
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local username = GetUserName()
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT Note FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND AddedBy = '" .. username .. "'";
	LogDebug(connection.QueryString);
	connection:Connect();
	local usernote = connection:ExecuteScalar();
	connection:Disconnect();
	
	if usernote ~= nil then
		return usernote;
	else
		return usernote_append;
	end
end

function HandleContextProcessing()

	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local RequestType = GetFieldValue("Transaction", "RequestType");
	local ProcessType = GetFieldValue("Transaction", "ProcessType");

	if ProcessType == "Borrowing" then
		if RequestType == "Loan" then		
			if rerun_checker() == false then
				ExecuteCommand("AddNote",{transactionNumber, "The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " ran on this transaction."});
				if validate_isbn() then
					local messageSent = false;
					local response;
	
					messageSent, response = pcall(build_hold_request);
			
					if (messageSent == false) then
						LogDebug('There was an error in the Alma_API from the build_hold_request function.  Sending TN to build_request function.');			
						return myerrorhandler(response);		
					else
						LogDebug('ALMA BORROWING REQUEST SENDER executed successfully.');
					end
				
				else
					ExecuteCommand("Route",{transactionNumber, Settings.NoISBNandNoOCLCNumberReviewQueue});
				end	
			end
		end
	end
end

function GetNVTGC()
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT NVTGC FROM Users WHERE Username = '" .. GetFieldValue("Transaction", "Username") .. "'";
	connection:Connect();
	local UserID = connection:ExecuteScalar();
	connection:Disconnect();
	return UserID;
end	

function GetUserName()
    local UserNameField = Settings.FieldtoUseForUserNameFromUsersTable;
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT " .. UserNameField .. " FROM Users WHERE Username = '" .. GetFieldValue("Transaction", "Username") .. "'";
	connection:Connect();
	local UserID = connection:ExecuteScalar();
	connection:Disconnect();
	return UserID;
end


function build_request()
if Settings.EnableSendingBorrowingRequests == true then
LogDebug("Initializing function build_request");
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

local user = GetUserName()


-- Get the user's matching pickup location and pickup location institution by using the sublibraries.txt crosswalk file		
local pickup_location_full = GetNVTGC()
local sublibraries = assert(io.open(AddonInfo.Directory .. "\\sublibraries.txt", "r"));
local pickup_location = "";
local pickup_location_type = "";
local first_split = "";
local second_split = "";
local templine = nil;
	if sublibraries ~= nil then
		for line in sublibraries:lines() do
			if string.find(line, pickup_location_full) ~= nil then
				first_split,second_split = line:match("(.+),(.+)");
				pickup_location_library = second_split;
				pickup_location_institution = Settings.Alma_Institution_Code;
				pickup_location_type = "LIBRARY";
				if pickup_location_library == "Home Delivery" then
					pickup_location_type = "USER_HOME_ADDRESS";
				end
				if pickup_location_library == "Office Delivery" then
					pickup_location_type = "USER_WORK_ADDRESS";
				end
				LogDebug("The pick up location library is: " .. pickup_location_library);
				LogDebug("The pick up location institution is: " .. pickup_location_institution);
				LogDebug("The pick up location type is: " .. pickup_location_type);
				break;
    		else
    			pickup_location = "nothing";
   			end
  		end
  	sublibraries:close();
	end

-- Assemble XML borrowing message to send to API
local loan_title = GetFieldValue("Transaction", "LoanTitle");
local isbn = GetFieldValue("Transaction", "ISSN");
local loan_author = GetFieldValue("Transaction", "LoanAuthor");
local loan_date = GetFieldValue("Transaction", "LoanDate");
local loan_publisher = GetFieldValue("Transaction", "LoanPublisher");
local loan_place = GetFieldValue("Transaction", "LoanPlace");
local loan_edition = GetFieldValue("Transaction", "LoanEdition");
local oclc_number = GetFieldValue("Transaction", "ESPNumber");
local usernotes = usernote_appender()

local ml = '<?xml version="1.0" encoding="ISO-8859-1"?><user_resource_sharing_request>';
	ml = ml .. '<format desc="string">';
	ml = ml .. '<xml_value>PHYSICAL</xml_value>';
	ml = ml .. '</format>';
	ml = ml .. '<pickup_location_type>' .. pickup_location_type .. '</pickup_location_type>';
	ml = ml .. '<pickup_location desc="string">';
	ml = ml .. '<xml_value>' .. pickup_location_library .. '</xml_value>';
	ml = ml .. '</pickup_location>';
	ml = ml .. '<citation_type desc="string">';
	ml = ml .. '<xml_value>BK</xml_value>';
	ml = ml .. '</citation_type>';
	if usernotes == "" then
	ml = ml .. '<note>Request created from ILLiad TN: ' .. transactionNumber_int .. '</note>';
	end
	if usernotes ~= "" then 
	ml = ml .. '<note>Request created from ILLiad TN: ' .. transactionNumber_int .. '. Note from Patron: ' .. usernotes .. '</note>';
	end
	if loan_title ~= nil then
	loan_title = cleanup_field(loan_title);
	ml = ml .. '<title>' .. loan_title .. '</title>';
	end
	if isbn ~= nil then
	ml = ml .. '<isbn>' .. isbn .. '</isbn>';
	end
	if loan_author ~= nil then
	loan_author = cleanup_field(loan_author);
	ml = ml .. '<author>' .. loan_author .. '</author>';
	end
	if loan_date ~= nil then
	ml = ml .. '<year>' .. loan_date .. '</year>';
	end
	if loan_publisher ~= nil then
	loan_publisher = cleanup_field(loan_publisher);
	ml = ml .. '<publisher>' .. loan_publisher .. '</publisher>';
	end
	if loan_place ~= nil then
	loan_place = cleanup_field(loan_place);
	ml = ml .. '<place_of_publication>' .. loan_place .. '</place_of_publication>';
	end
	if loan_edition ~= nil then
	ml = ml .. '<edition>' .. loan_edition .. '</edition>';
	end
	ml = ml .. '<call_number>Imported from ILLiad</call_number>';	
	if oclc_number ~= nil then
	ml = ml .. '<oclc_number>' .. oclc_number .. '</oclc_number>';
	end
	ml = ml .. '</user_resource_sharing_request>';
	
LogDebug("Alma Message: " .. ml);

-- Assemble URL for connecting to Users API
local alma_url = Settings.Alma_Base_URL .. '/users/' .. user .. '/resource-sharing-requests?user_id_type=all_unique&override_blocks=true&apikey=' .. Settings.Alma_Users_API_Key;
local alma_url_for_printing = Settings.Alma_Base_URL .. '/users/' .. user .. '/resource-sharing-requests?user_id_type=all_unique&override_blocks=true&apikey=YOUR_KEY';

	
		--LogDebug("Borrowing Message prepared for sending: " .. ml);
		--LogDebug("Alma URL prepared for connection: " .. alma_url);
		LogDebug("Creating web client.");
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
       	webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("accept", "application/xml; charset=UTF-8");
		LogDebug("Sending Borrowing Message to Alma API using URL: " .. alma_url_for_printing);
			
		local responseString = webClient:UploadString(alma_url, ml);
		--LogDebug("Alma API Server Response: " .. responseString);

		-- if there is "<user_request>" tag in the response, then it was Successful
        -- if there is not a "<user_request>" tag in the response, the Addon will handle the error in the myerrorhandler2() function
		if string.find(responseString, "<user_resource_sharing_request>") then
			LogDebug("No Problems found in Alma Users API Response.");
			ExecuteCommand("Route",{transactionNumber_int, Settings.ItemSuccessQueue});
			ExecuteCommand("AddNote",{transactionNumber_int, "Alma API Response for Alma Borrowing Request Sender received successfully"});
			--ExecuteCommand("AddNote",{transactionNumber_int, "Alma API Successful Response: " .. responseString});
			SaveDataSource("Transaction");	
			return true
		end
	
	end
	if Settings.EnableSendingBorrowingRequests == false then
	LogDebug("The setting: EnableSendingBorrowingRequests is set to false. A Borrowing Request was not sent from the Addon.");
	return true
	end
end

function check_excluder(shelving_location)
LogDebug("Initializing function check_excluder");
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);
	local excluded_locations = assert(io.open(AddonInfo.Directory .. "\\excluded_locations.txt", "r"));
	if excluded_locations ~= nil then
		for line in excluded_locations:lines() do
			--LogDebug(line)
			--if line == shelving_location then
				--LogDebug("We have a match! [" .. shelving_location .. "]");
			--end
			if string.find(line, shelving_location) ~= nil then
				--LogDebug("Message from check_excluder function: The shelving location [" .. shelving_location .. "] is on the Exclude list.");
				ExecuteCommand("AddNote",{transactionNumber_int, "Message from check_excluder function: The shelving location [" .. shelving_location .. "] is on the Exclude list."});
				return true;
			end

		end
	end
end


function check_process_type_router(the_process_type)
local the_process_type = the_process_type;
LogDebug("Initializing function check_process_type_router for process type: [" .. the_process_type .. "]");
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);
local first_split = "";
local second_split = "";

	local routing_for_process_types = assert(io.open(AddonInfo.Directory .. "\\process_type_router.txt", "r"));
	if routing_for_process_types ~= nil then
		for line in routing_for_process_types:lines() do
			--LogDebug(line)
			--if line == the_process_type then
				--LogDebug("We have a match! [" .. the_process_type .. "]");
			--end
			if string.find(line, the_process_type) ~= nil then
				first_split,second_split = line:match("(.+),(.+)");
				local process_type_phrase = first_split;
				local process_type_routing_queue_name = second_split;
				LogDebug("Message from check_process_type_router function: The process type [" .. the_process_type .. "] is on the process_type_router.txt file.  Routing TN to " .. process_type_routing_queue_name);				
				ExecuteCommand("AddNote",{transactionNumber_int, "Message from check_process_type_router function: The process type [" .. the_process_type .. "] is on the process_type_router.txt file.  Routing TN to " .. process_type_routing_queue_name });
				ExecuteCommand("Route",{transactionNumber_int, process_type_routing_queue_name});
				return true;
			end

		end
	end
end

function check_item_process_type(MMSID)
local MMSID = MMSID;
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

local bibs_url = Settings.Alma_Base_URL .. "/bibs/" .. MMSID .. "/holdings/ALL/items?limit=10&offset=0&order_by=none&direction=desc&view=brief&apikey=" .. Settings.Alma_Bibs_API_Key;

local bibs_url_for_print = Settings.Alma_Base_URL .. "/bibs/" .. MMSID .. "/holdings/ALL/items?limit=10&offset=0&order_by=none&direction=desc&view=brief&apikey=YOUR_API_KEY";

LogDebug(bibs_url_for_print);

LogDebug("Creating Bibs web client to lookup holdings for MMSID: " .. MMSID);
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
		webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
		LogDebug("Sending MMSID to retrieve holdings from Bibs API.");
		local responseString = webClient:DownloadString(bibs_url);
				
		if string.find(responseString, 'item link') ~= nil then
		--LogDebug(responseString);
		local process_type = responseString:match('<process_type(.-)</process_type>'):gsub('(.-)>', ''); -- look for process_type
			if process_type ~= "" then
				LogDebug("The item is showing a process_type of [" .. process_type .. "]");
				if process_type == "ILL" then
					LogDebug("Item is currently on Loan through Resource Sharing. Leaving note on transaction: " .. tostring(transactionNumber_int));
					ExecuteCommand("AddNote",{transactionNumber_int, "From ALMA BORROWING REQUEST SENDER: Item is currently on Loan through Resource Sharing"});
				end
				
				if check_process_type_router(process_type) then
					return true;
				end
			end		
			if process_type == "" then
				LogDebug("No process_type found. Continue on.");
			end
		end	
end

	
	
function check_user_loans(MMSID)
LogDebug("Initializing function check_user_loans");
local user = GetUserName()
local MMSID = MMSID;

		local user_loans_url = Settings.Alma_Base_URL .. '/users/' .. user .. '/loans?user_id_type=all_unique&limit=10&offset=0&order_by=id&direction=ASC&loan_status=Active&apikey=' .. Settings.Alma_Users_API_Key;
		local user_loans_url_for_print = Settings.Alma_Base_URL .. '/users/' .. user .. '/loans?user_id_type=all_unique&limit=10&offset=0&order_by=id&direction=ASC&loan_status=Active&apikey=YOUR_KEY';
        LogDebug("Assembling User Loans Lookup URL: " .. user_loans_url_for_print);
		LogDebug("Creating web client.");
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
		webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
		LogDebug("Retrieving User Requests using Alma Users API.");
		local responseString = webClient:DownloadString(user_loans_url);
		--LogDebug(responseString);
		
		if string.find(responseString, MMSID) then
			local Requested_MMSID = responseString:match('<mms_id>' .. MMSID .. '</mms_id>');
		
			if Requested_MMSID ~= nil then
			LogDebug("The user has a duplicate request already on Loan. Stopping Alma Borrowing Request Sender Addon.");
			
			local currentTN = GetFieldValue("Transaction", "TransactionNumber");
			local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);
			
			ExecuteCommand("AddNote",{transactionNumber_int, "The user has a duplicate request already on Loan. Stopping Alma Borrowing Request Sender Addon."});
		
				if Settings.ItemFailHoldRequestQueue ~= "" then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
					return true;
				end
				if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
					return true;
				end		
		
			end
		end
		if not string.find(responseString, MMSID) then
		LogDebug("The user does not have a duplicate request already on Loan. Continue on.");
		return false;
		end

end	


function build_hold_request_sender(MMSID)
LogDebug("Initializing function build_hold_request_sender");
local MMSID = MMSID;
local user = GetUserName()
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

if Settings.EnableSendingHoldRequests == true then
-- Get the user's matching pickup location and pickup location institution by using the sublibraries.txt crosswalk file	
local pickup_location_full = GetNVTGC()
local sublibraries = assert(io.open(AddonInfo.Directory .. "\\sublibraries.txt", "r"));
local pickup_location_type = "";
local pickup_location = "";
local first_split = "";
local second_split = "";
local templine = nil;
	if sublibraries ~= nil then
		for line in sublibraries:lines() do
			if string.find(line, pickup_location_full) ~= nil then
				first_split,second_split = line:match("(.+),(.+)");
				pickup_location_library = second_split;
				pickup_location_institution = Settings.Alma_Institution_Code;
				pickup_location_type = "LIBRARY";
				if pickup_location_library == "Home Delivery" then
				pickup_location_type = "USER_HOME_ADDRESS";
				end
				if pickup_location_library == "Office Delivery" then
				pickup_location_type = "USER_WORK_ADDRESS";
				end
				LogDebug("The pick up location library is: " .. pickup_location_library);
				LogDebug("The pick up location institution is: " .. pickup_location_institution);
				LogDebug("The pick up location type is: " .. pickup_location_type);
				break;
    		else
    			pickup_location = "nothing";
   			end
  		end
  	sublibraries:close();
	end
	
-- Assemble XML hold message to send to API
local hold_message = '<?xml version="1.0" encoding="ISO-8859-1"?><user_request><request_type>HOLD</request_type><pickup_location_type>' .. pickup_location_type .. '</pickup_location_type><pickup_location_library>' .. pickup_location_library .. '</pickup_location_library><pickup_location_institution>' .. pickup_location_institution .. '</pickup_location_institution></user_request>';
--LogDebug(hold_message);

-- Assemble URL for connecting to Users API
local alma_url = Settings.Alma_Base_URL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=false&apikey=' .. Settings.Alma_Users_API_Key;
local alma_url_for_message = Settings.Alma_Base_URL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=false&apikey=YOUR_KEY'; 

	
		LogDebug("Hold Message prepared for sending: " .. hold_message);
		LogDebug("Alma URL prepared for connection: " .. alma_url_for_message);
		LogDebug("Creating web client for Alma HOLD message.");
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
       	webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("accept", "application/xml; charset=UTF-8");
		LogDebug("Sending Hold Message to Alma Users API.");
				
		local responseString = webClient:UploadString(alma_url, hold_message);

		if string.find(responseString, "<user_request>") then
			LogDebug("No Problems found in Alma Users HOLD API Response.");
			ExecuteCommand("Route",{transactionNumber_int, Settings.ItemSuccessHoldRequestQueue});
			ExecuteCommand("AddNote",{transactionNumber_int, "Alma API Response for HOLD received successfully"});
			--ExecuteCommand("AddNote",{transactionNumber_int, "Alma API Successful Response: " .. responseString});
			SaveDataSource("Transaction");	
			return true;
		end
	end 	
end -- end function

function analyze_ava_tag(responseString)
LogDebug("Initializing function analyze_ava_tag");
	local is_record_found = false;
	local is_item_available = false;
	local is_location_permitted_for_use = false;
	local use_record = true;
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN_int);

		if string.find(responseString, '<datafield ind1=" " ind2=" " tag="AVA">') ~= nil then	
		local mmsid_list = "";
		local is_item_available = false;
			for ava_blocks in string.gmatch(responseString, '<datafield ind1=" " ind2=" " tag="AVA">(.-)</datafield>') do -- for every AVE tag block, do the following
				if string.find(ava_blocks, '<subfield code="0">') ~= nil then  --if the block has an MMSID then
					-------------DETERMINING MMSID-------------
					local MMSID = ava_blocks:match('<subfield code="0">(.-)<'):gsub('(.-)>', ''); -- look for MMSID
					LogDebug("MMSID: " .. MMSID);		
					local mmsid_list = MMSID .. "," .. mmsid_list;
					-------------CHECKING USER'S CURRENT LOANS-------------
					if check_user_loans(MMSID) then
						return true
					end			
					-------------DETERMINING AVAILABILITY-------------
					local availability_message = ava_blocks:match('<subfield code="e">(.-)<'):gsub('(.-)>', ''); -- look for availability in subfield e
					LogDebug("availability_message: " .. availability_message);
					if availability_message == "unavailable" or availability_message == "Unavailable" then
						use_record = false;
						is_item_available = false;
						LogDebug("The MMSID: " .. MMSID .. " is showing as " .. availability_message);
						LogDebug("Preparing to connect to Bibs API to determine if there is a process_type (e.g., MISSING)");
						if check_item_process_type(MMSID) then		
							return true;
						end
					
					end
					if availability_message == "Available" or availability_message == "available" then
						LogDebug("The MMSID: " .. MMSID .. " is showing as " .. availability_message);
						is_item_available = true;
					end
					-------------DETERMINING LOCATION-------------
					local shelving_location = "";
					if string.find(ava_blocks, '<subfield code="c">') ~= nil then -- if the block has a location (in subfield m) then get location, else skip location retrieval
						shelving_location = ava_blocks:match('<subfield code="c">(.-)<'):gsub('(.-)>', '');			
						LogDebug("Location: " .. shelving_location);
						local check_excluder_return = check_excluder(shelving_location)
						if check_excluder_return then
						is_location_permitted_for_use = false;
						use_record = false;
						LogDebug("[The location: [" .. shelving_location .. "] is on the exclude list. Skipping record.");
						end
						if not check_excluder_return then
							is_location_permitted_for_use = true;
							LogDebug("This location permitted for Holds and Borrowing: [" .. shelving_location .. "]");							
							if is_item_available then
								use_record = true;
							end
						end			
					end
					if string.find(ava_blocks, '<subfield code="c">') == nil then  -- if it cannot find subfield c, leave a note
						LogDebug("From Alma SRU > Cannot Determine Location.  The <subfield code='c'> is blank in the AVE tag from the SRU return.");
						is_location_permitted_for_use = true;
					end	

					if is_item_available and is_location_permitted_for_use then
						is_record_found = true;
						LogDebug("Found available item for MMSID: " .. MMSID);
						if build_hold_request_sender(MMSID) then
							return true;
						end
					end				
				end --if the block has an MMSID then
			end -- for loop
			if use_record == false then
			LogDebug("No Available items found for MMSID record(s): " .. mmsid_list:sub(1, -2));
				if is_location_permitted_for_use == false then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemInExcludedLocationNeedsReviewQueue});
					ExecuteCommand("AddNote",{transactionNumber_int,"The location is on the exclude list. Routing to Review Queue."});
					return true;
				end
				if is_location_permitted_for_use == true then
					if Settings.EnableSendingBorrowingRequests == true then
					LogDebug("The item is currently checked out. Attempting to send Borrowing Requests.");
						build_request()
					end
					if Settings.EnableSendingBorrowingRequests == false then
						LogDebug("EnableSendingHoldRequests is set to false and there are no available items for a Hold Request. Routing TN to failure queue.");
						ExecuteCommand("AddNote",{transactionNumber_int,"The item is currently checked out. Sending Borrowing Requests is disabled in the config.  Routing to failure queue."});
						if Settings.ItemFailHoldRequestQueue ~= "" then
							ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
							return true;
						end
						if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
							ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
							return true;
						end		
					end
				end				
			end
		end -- if AVA tag		
end -- function


function analyze_ave_tag(responseString)
LogDebug("Initializing function analyze_ave_tag");
	local is_record_found = false;
	local is_item_available = false;
	local is_location_permitted_for_use = false;
	local use_record = true;
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN_int);

	if string.find(responseString, '<datafield ind1=" " ind2=" " tag="AVE">') ~= nil then	
	local mmsid_list = "";
		if string.find(responseString, 'tag="856">') ~= nil then
		for ave_record in string.gmatch(responseString, '<recordData>(.-)</recordData>') do
			if string.find(ave_record, 'tag="856">') ~= nil then
			for ave_blocks in string.gmatch(ave_record, '<datafield ind1=" " ind2=" " tag="AVE">(.-)</datafield>') do -- for every AVE tag block that has a record with an 856, do the following
				if string.find(ave_blocks, '<subfield code="0">') ~= nil then  --if the block has an MMSID then
					local MMSID = ave_blocks:match('<subfield code="0">(.-)<'):gsub('(.-)>', ''); -- look for MMSID
					LogDebug("MMSID: " .. MMSID);		
					local mmsid_list = MMSID .. "," .. mmsid_list;
					-------------DETERMINING AVAILABILITY-------------
					local availability_message = ave_blocks:match('<subfield code="e">(.-)<'):gsub('(.-)>', ''); -- look for availability in subfield e
					LogDebug("availability_message: " .. availability_message);
					if availability_message == "unavailable" or availability_message == "Unavailable" then
						use_record = false;
						is_item_available = false;
						LogDebug("The MMSID: " .. MMSID .. " is showing as " .. availability_message);
					end
					if availability_message == "Available" or availability_message == "available" then
						is_item_available = true;
						LogDebug("The MMSID: " .. MMSID .. " is showing as " .. availability_message);
					end
					-------------DETERMINING LOCATION-------------
					local shelving_location = "";
					if string.find(ave_blocks, '<subfield code="m">') ~= nil then -- if the block has a location (in subfield m) then get location, else skip location retrieval
						shelving_location = ave_blocks:match('<subfield code="m">(.-)<'):gsub('(.-)>', '');			
						LogDebug("Location: " .. shelving_location);
						local check_excluder_return = check_excluder(shelving_location)
						if check_excluder_return then
						is_location_permitted_for_use = false;
						use_record = false;
						LogDebug("[The location: [" .. shelving_location .. "] is on the exclude list. Skipping record.");
						end
						if not check_excluder_return then
						is_location_permitted_for_use = true;
						LogDebug("This location permitted for Holds and Borrowing: [" .. shelving_location .. "]");
							if is_item_available then
								use_record = true;	
							end
						end			
					end
					if string.find(ave_blocks, '<subfield code="m">') == nil then  -- if it cannot find subfield m, leave a note
						LogDebug("From Alma SRU > Cannot Determine Location.  The <subfield code='m'> is blank in the AVE tag from the SRU return.");
						is_location_permitted_for_use = true;
					end	
									
					if is_item_available and is_location_permitted_for_use then
						--if not check_user_loans(MMSID) then
							is_record_found = true;
							LogDebug("Found available electronic item with URL in 856u field for MMSID: " .. MMSID);
							local url_for_item = ave_record:match('tag="856">(.-)</datafield>'):match('<subfield code="u">(.-)</subfield>');
							if url_for_item ~= nil then
								LogDebug("The URL for the item is: " .. url_for_item);
								ExecuteCommand("AddNote",{transactionNumber_int, "Alma Borrowing Request Sender: Local Electronic availablity at: " .. url_for_item});
								SetFieldValue("Transaction", Settings.ILLiadFieldforElectronicItemURL, url_for_item);	
								SaveDataSource("Transaction");
								ExecuteCommand("Route",{transactionNumber_int, Settings.ElectronicItemSuccessQueue});
								return true;
							end
						--end
					end		
				end --if the block has an MMSID then
			end -- for loop
			if use_record == false then
			LogDebug("No Available items found for MMSID record(s): " .. mmsid_list:sub(1, -2));
				if is_location_permitted_for_use == false then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemInExcludedLocationNeedsReviewQueue});
					ExecuteCommand("AddNote",{transactionNumber_int,"The location is on the exclude list. Routing to Review Queue."});
					return true;
				end
				if is_location_permitted_for_use == true then
					if Settings.EnableSendingBorrowingRequests == true then
					LogDebug("The item is currently checked out. Attempting to send Borrowing Requests.");
						build_request()
					end
					if Settings.EnableSendingBorrowingRequests == false then
						LogDebug("EnableSendingHoldRequests is set to false and there are no available items for a Hold Request. Routing TN to failure queue.");
						ExecuteCommand("AddNote",{transactionNumber_int,"The item is currently checked out. Sending Borrowing Requests is disabled in the config.  Routing to failure queue."});
						if Settings.ItemFailHoldRequestQueue ~= "" then
							ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
							return true;
						end
						if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
							ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
							return true;
						end		
					end
				end
			end
		end -- if 856 in for loop
		end -- for loop for records	
	end -- check for 856
	
	if string.find(responseString, 'tag="856">') == nil then
		is_record_found = true;
		ExecuteCommand("Route",{transactionNumber_int, Settings.ElectronicItemReviewQueue});
		return true;
	end -- end NO 856 tag return
	
	end -- if AVE tag
end -- function


function build_hold_request()
LogDebug("Initializing function build_hold_request");
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

local isbn = GetFieldValue("Transaction", "ISSN");
local oclc_number = GetFieldValue("Transaction", "ESPNumber");

local used_oclc_number = false;
local used_isbn = false;

local sru_url = "";
local records_found = "";
local responseString = "";

if isbn == "" and oclc_number == "" then
	LogDebug("No ISBN or OCLC Number found in Transaction.  Please add the ISBN or OCLC Number and reprocess Transasction.");
	-- Route for review (put config in for queue name)
	ExecuteCommand("Route",{transactionNumber_int, Settings.NoISBNandNoOCLCNumberReviewQueue});
	return true;
end

-- Settings.Alma_Institution_Code
--local sru_url_isbn = "https://suny-gen.alma.exlibrisgroup.com/view/sru/01SUNY_GEN?version=1.2&operation=searchRetrieve&recordSchema=marcxml&query=alma.isbn=" .. isbn .. "&maximumRecords=3";

if oclc_number ~= "" then
	sru_url = Settings.Full_Alma_URL .. "/view/sru/" .. Settings.Alma_Institution_Code .. "?version=1.2&operation=searchRetrieve&recordSchema=marcxml&query=alma.oclc_control_number_035_a=" .. oclc_number .. "&maximumRecords=3";
	used_oclc_number = true;
end

if isbn ~= "" then 
	sru_url = Settings.Full_Alma_URL .. "/view/sru/" .. Settings.Alma_Institution_Code .. "?version=1.2&operation=searchRetrieve&recordSchema=marcxml&query=alma.isbn=" .. isbn .. "&maximumRecords=3";
	used_isbn = true;
	used_oclc_number = false;
end

LogDebug(sru_url);

	if used_isbn then
		LogDebug("Creating SRU web client to lookup ISBN: " .. isbn);
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
		webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
		LogDebug("Sending ISBN to Retrieve MMSID.");
		responseString = webClient:DownloadString(sru_url);
		--LogDebug(responseString);
		
		records_found = responseString:match('numberOfRecords>(.-)<'):gsub('(.-)>', '');
		--LogDebug(records_found);
	end
	
	if used_oclc_number then
		LogDebug("Creating SRU web client to lookup OCLC Number: " .. oclc_number);
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
		webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
		LogDebug("Sending OCLC Number to Retrieve MMSID.");
		responseString = webClient:DownloadString(sru_url);
		--LogDebug(responseString);	
		records_found = responseString:match('numberOfRecords>(.-)<'):gsub('(.-)>', '');
		--LogDebug(records_found);
	end
	
		
	if records_found ~= "0" then
		
		if used_isbn then
			LogDebug("This number of records were found for ISBN " .. isbn .. ": " .. records_found);
		end
		if used_oclc_number then
			LogDebug("This number of records were found for OCLC Number " .. oclc_number .. ": " .. records_found);
		end
				
		if Settings.PreferElectronicOverPrintForHoldRequests == true then		
			if analyze_ave_tag(responseString) ~= true then
				LogDebug("The AVE lookup did not return any electronic items to create a Hold request. Attempting AVA lookup.");
				if analyze_ava_tag(responseString) ~= true then
					LogDebug("The AVE lookup and AVA lookup did not return any available items to create a Hold request.");
				end
			end
		end
		
		if Settings.PreferElectronicOverPrintForHoldRequests == false then		
			if analyze_ava_tag(responseString) ~= true then
				LogDebug("The AVA lookup did not return any physical items to create a Hold request. Attempting AVE lookup.");
				if analyze_ave_tag(responseString) ~= true then
					LogDebug("The AVA lookup and AVE lookup did not return any available items to create a Hold request");
				end
			end
		end

		
		if Settings.EnableSendingHoldRequests == false then
			LogDebug("The setting: EnableSendingHoldRequests is set to false. A Hold Request was not sent from the Addon.");
			if Settings.EnableSendingBorrowingRequests == true then
				build_request()
			end
			if Settings.EnableSendingBorrowingRequests == false then
			LogDebug("The settings: EnableSendingHoldRequests and EnableSendingHoldRequests are set to false. One of these settings must be set to true for the Addon to function.");
			end
		end
	end -- if records found is not zero		

	if records_found == "0" then
		if Settings.EnableSendingHoldRequests == true then
			if Settings.EnableSendingBorrowingRequests == false then
				LogDebug("There are 0 local holdings and EnableSendingBorrowingRequests is set to false. Routing TN to: " .. Settings.ItemFailHoldRequestQueue);
				ExecuteCommand("AddNote",{transactionNumber_int,"There are 0 local holdings and EnableSendingBorrowingRequests is set to false. Routing TN to: " .. Settings.ItemFailHoldRequestQueue});
				ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});	
				return true
			end
			if Settings.EnableSendingBorrowingRequests == true then
				LogDebug("There are 0 local holdings. Attempting to send Borrowing Request to Alma.");
				build_request()
			end
		end
		
		if Settings.EnableSendingHoldRequests == false then
			LogDebug("The setting: EnableSendingHoldRequests is set to false. A Hold Request was not sent from the Addon.");
			if Settings.EnableSendingBorrowingRequests == true then
				LogDebug("There are 0 local holdings. Attempting to send Borrowing Request to Alma.");
				build_request()
			end
			if Settings.EnableSendingBorrowingRequests == false then
			LogDebug("The settings: EnableSendingHoldRequests and EnableSendingHoldRequests are set to false. One of these settings must be set to true for the Addon to function.");
			return true
			end
		end
	end -- if records_found == "0"
end -- function