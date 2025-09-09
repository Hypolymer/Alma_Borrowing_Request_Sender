-- Alma Borrowing Request Sender, version 1.26 (creation date: December 25, 2023)
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
Settings.AlmaBaseURL = GetSetting("AlmaBaseURL");
Settings.AlmaUsersAPIKey = GetSetting("AlmaUsersAPIKey");
Settings.AlmaBibsAPIKey = GetSetting("AlmaBibsAPIKey");
Settings.SRULookupUsername = GetSetting("SRULookupUsername");
Settings.SRULookupPassword = GetSetting("SRULookupPassword");
Settings.ItemSearchQueue = GetSetting("ItemSearchQueue");
Settings.ItemSuccessQueue = GetSetting("ItemSuccessQueue");
Settings.ItemFailQueue = GetSetting("ItemFailQueue");
Settings.ItemSuccessHoldRequestQueue = GetSetting("ItemSuccessHoldRequestQueue");
Settings.ItemFailHoldRequestQueue = GetSetting("ItemFailHoldRequestQueue");
Settings.AlmaInstitutionCode = GetSetting("AlmaInstitutionCode");
Settings.FieldtoUseForUserNameFromUsersTable = GetSetting("FieldtoUseForUserNameFromUsersTable");
Settings.FullAlmaURL = GetSetting("FullAlmaURL");
Settings.EnableSendingBorrowingRequests = GetSetting("EnableSendingBorrowingRequests");
Settings.EnableSendingHoldRequests = GetSetting("EnableSendingHoldRequests");
Settings.ElectronicItemSuccessQueue = GetSetting("ElectronicItemSuccessQueue");
Settings.ILLiadFieldforElectronicItemURL = GetSetting("ILLiadFieldforElectronicItemURL");
Settings.NoISBNandNoOCLCNumberReviewQueue = GetSetting("NoISBNandNoOCLCNumberReviewQueue");
Settings.ItemInExcludedLocationNeedsReviewQueue = GetSetting("ItemInExcludedLocationNeedsReviewQueue");
Settings.AddonWorkerName = GetSetting("AddonWorkerName");
Settings.PreferElectronicOverPrintForHoldRequests = GetSetting("PreferElectronicOverPrintForHoldRequests");
Settings.ILLiadFieldToStorePIDs = GetSetting("ILLiadFieldToStorePIDs");
Settings.MultiVolumeRewiewQueue = GetSetting("MultiVolumeRewiewQueue");
Settings.PrimoPermalinkPrefix = GetSetting("PrimoPermalinkPrefix");
Settings.UltimateDebug = GetSetting("UltimateDebug");

local isCurrentlyProcessing = false;
local client = nil;

-- Assembly Loading and Type Importation
luanet.load_assembly("System");
local Types = {};
Types["WebClient"] = luanet.import_type("System.Net.WebClient");
Types["System.IO.StreamReader"] = luanet.import_type("System.IO.StreamReader");
Types["System.Type"] = luanet.import_type("System.Type");

MMSID = "";
myPIDchecker = true;
myFailedPIDs = {};
hold_send_rerun_count = 0;
check_allow_duplicate_requests_for_holds = false;
check_allow_duplicate_requests_for_loans = false;
check_user_has_current_loan = false;
check_user_has_current_hold = false;
tn_has_no_identifier = false;

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


-- this function converts a string to base64
-- https://devforum.roblox.com/t/base64-encoding-and-decoding-in-lua/1719860
function to_base64(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x) 
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

function extract_isbn(isbn)		
local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
local isbn = isbn;
	isbn = isbn:gsub('-', '');
	LogDebug("Attempting to extract ISBN from: " .. isbn);
	
	if string.find(isbn, '%d%d%d%d%d%d%d%d%d%d%d%d%d') then
		local i = string.match(isbn, '%d%d%d%d%d%d%d%d%d%d%d%d%d');
		LogDebug("Extracted ISBN: " .. i .. " from original ISBN: " .. isbn);
		new_ISBN = i;
		if validate_isbn(new_ISBN) then
			ExecuteCommand("AddNote",{transactionNumber, "Extracted ISBN: " .. i .. " from original ISBN: " .. isbn});
			SetFieldValue("Transaction", "ISSN", new_ISBN);
			SaveDataSource("Transaction");
			return new_ISBN;		
		else
			LogDebug("The Extracted ISBN: " .. i .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess.");
			ExecuteCommand("AddNote",{transactionNumber, "The Extracted ISBN: " .. i .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess."});
			return false
		end	
	end
	
	if string.find(isbn, '%d%d%d%d%d%d%d%d%d%d%d%d' .. "X") then
		local j = string.match(isbn, '%d%d%d%d%d%d%d%d%d%d%d%d' .. "X");
		LogDebug("Extracted ISBN: " .. j .. " from original ISBN: " .. isbn);
		new_ISBN = j;
		if validate_isbn(new_ISBN) then
			ExecuteCommand("AddNote",{transactionNumber, "Extracted ISBN: " .. j .. " from original ISBN: " .. isbn});
			SetFieldValue("Transaction", "ISSN", new_ISBN);
			SaveDataSource("Transaction");
			return new_ISBN;		
		else
			LogDebug("The Extracted ISBN: " .. j .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess.");
			ExecuteCommand("AddNote",{transactionNumber, "The Extracted ISBN: " .. j .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess."});
			return false
		end
	end
	
	if string.find(isbn, '%d%d%d%d%d%d%d%d%d%d%d%d' .. "x") then
		local j = string.match(isbn, '%d%d%d%d%d%d%d%d%d%d%d%d' .. "x");
		LogDebug("Extracted ISBN: " .. j .. " from original ISBN: " .. isbn);
		new_ISBN = j;
		if validate_isbn(new_ISBN) then
			ExecuteCommand("AddNote",{transactionNumber, "Extracted ISBN: " .. j .. " from original ISBN: " .. isbn});
			SetFieldValue("Transaction", "ISSN", new_ISBN);
			SaveDataSource("Transaction");
			return new_ISBN;		
		else
			LogDebug("The Extracted ISBN: " .. j .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess.");
			ExecuteCommand("AddNote",{transactionNumber, "The Extracted ISBN: " .. j .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess."});
			return false
		end
	end
			
	if string.find(isbn, '%d%d%d%d%d%d%d%d%d%d') then
		local i = string.match(isbn, '%d%d%d%d%d%d%d%d%d%d');
		LogDebug("Extracted ISBN: " .. i .. " from original ISBN: " .. isbn);	
		new_ISBN = i;
		if validate_isbn(new_ISBN) then
			ExecuteCommand("AddNote",{transactionNumber, "Extracted ISBN: " .. i .. " from original ISBN: " .. isbn});
			SetFieldValue("Transaction", "ISSN", new_ISBN);
			SaveDataSource("Transaction");
			return new_ISBN;		
		else
			LogDebug("The Extracted ISBN: " .. i .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess.");
			ExecuteCommand("AddNote",{transactionNumber, "The Extracted ISBN: " .. i .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess."});
			return false
		end
	end
	
	if string.find(isbn, '%d%d%d%d%d%d%d%d%d' .. "X") then
		local j = string.match(isbn, '%d%d%d%d%d%d%d%d%d' .. "X");
		LogDebug("Extracted ISBN: " .. j .. " from original ISBN: " .. isbn);
		new_ISBN = j;
		if validate_isbn(new_ISBN) then
			ExecuteCommand("AddNote",{transactionNumber, "Extracted ISBN: " .. j .. " from original ISBN: " .. isbn});
			SetFieldValue("Transaction", "ISSN", new_ISBN);
			SaveDataSource("Transaction");
			return new_ISBN;		
		else
			LogDebug("The Extracted ISBN: " .. j .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess.");
			ExecuteCommand("AddNote",{transactionNumber, "The Extracted ISBN: " .. j .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess."});
			return false
		end
	end
	
	if string.find(isbn, '%d%d%d%d%d%d%d%d%d' .. "x") then
		local j = string.match(isbn, '%d%d%d%d%d%d%d%d%d' .. "x");
		LogDebug("Extracted ISBN: " .. j .. " from original ISBN: " .. isbn);
		new_ISBN = j;
		if validate_isbn(new_ISBN) then
			ExecuteCommand("AddNote",{transactionNumber, "Extracted ISBN: " .. j .. " from original ISBN: " .. isbn});
			SetFieldValue("Transaction", "ISSN", new_ISBN);
			SaveDataSource("Transaction");
			return new_ISBN;		
		else
			LogDebug("The Extracted ISBN: " .. j .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess.");
			ExecuteCommand("AddNote",{transactionNumber, "The Extracted ISBN: " .. j .. " from original ISBN: " .. isbn .. " is not a valid ISBN. Please try to manually fix the ISBN for the transaction and reprocess."});
			return false
		end
	end
end

function validate_isbn(isbn)
LogDebug("Initializing ISBN Validator.");

local isbn = isbn;

if isbn == "" or isbn == nil then
LogDebug("ISBN Validator > There is no ISBN available.  Skipping ISBN Validator.");
return "missing ISBN";
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

function statusChecker()
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT TransactionStatus FROM Transactions WHERE TransactionNumber = '" .. transactionNumber .. "'";
	connection:Connect();
	local rerun_status = connection:ExecuteScalar();
	connection:Disconnect();
	return rerun_status
end

function splitString(inputStr)
	local t = {}
	for str in string.gmatch(inputStr, "([^%s]+)") do
		table.insert(t,str)
	end
	return t
end

function rerun_checker()
	LogDebug("Initializing function rerun_checker");
    local has_it_run = false;
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT TransactionNumber FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND NOTE = 'The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " ran on this transaction.'";
	connection:Connect();
	local rerun_status = connection:ExecuteScalar();
	connection:Disconnect();
	if rerun_status == transactionNumber then
		LogDebug('rerun_checker > The ALMA BORROWING REQUEST SENDER already ran on transaction ' .. transactionNumber .. '. Now Stopping Addon.');
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
	LogDebug("rerun_checker > has_it_run equals: " .. tostring(has_it_run));
	return has_it_run;
end

function usernote_appender()
    local usernote_append = "";
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local username = GetUserName()
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT Note FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND AddedBy = '" .. username .. "'";
	LogDebug("usernote_appender > " .. connection.QueryString);
	connection:Connect();
	local usernote = connection:ExecuteScalar();
	connection:Disconnect();
	
	if usernote ~= nil then
		return usernote;
	else
		return usernote_append;
	end
end

function check_excluder_bypass()
	LogDebug("Initializing function check_excluder_bypass");
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT Note FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND LOWER(Note) = 'bypass'";
	LogDebug("check_excluder_bypass > " .. connection.QueryString);
	connection:Connect();
	local bypass = connection:ExecuteScalar();
	connection:Disconnect();
	
	if bypass ~= nil then
		ExecuteCommand("AddNote",{transactionNumber, "The check_excluder_bypass function found the note to bypass excluded locations or process types. Attempting to process transaction."});
		LogDebug("check_excluder_bypass > The check_excluder_bypass function found the note to bypass excluded locations or process types. Attempting to process transaction.");
		return true
	else
		LogDebug("check_excluder_bypass > The check_excluder_bypass function did not find a note to bypass excluded locations or process types.");
		return false
	end
end

function check_print_override()
	LogDebug("Initializing function check_print_override");
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT Note FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND LOWER(Note) = 'print override'";
	LogDebug("check_print_override > " .. connection.QueryString);
	connection:Connect();
	local bypass = connection:ExecuteScalar();
	connection:Disconnect();
	
	if bypass ~= nil then
		ExecuteCommand("AddNote",{transactionNumber, "The check_print_override function found the note to bypass electronic items and only select print items. Attempting to process transaction."});
		LogDebug("check_print_override > The check_print_override function found the note to bypass electronic items and only select print items. Attempting to process transaction.");
		return true
	else
		LogDebug("check_print_override > The check_print_override function did not find the note 'print override' to only select print items.");
		return false
	end
end

function check_electronic_override()
	LogDebug("Initializing function check_electronic_override");
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT Note FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND LOWER(Note) = 'electronic override'";
	LogDebug("check_electronic_override > " .. connection.QueryString);
	connection:Connect();
	local bypass = connection:ExecuteScalar();
	connection:Disconnect();
	
	if bypass ~= nil then
		ExecuteCommand("AddNote",{transactionNumber, "The check_electronic_override function found the note to bypass print items and only select electronic items. Attempting to process transaction."});
		LogDebug("check_electronic_override > The check_electronic_override function found the note to bypass print items and only select electronic items. Attempting to process transaction.");
		return true
	else
		LogDebug("check_electronic_override > The check_electronic_override function did not find the note 'electronic override' to bypass print items and only select electronic items.");
		return false
	end
end

function check_allow_for_duplicate_requests_for_holds()
	LogDebug("Initializing function check_allow_for_duplicate_requests_for_holds");
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT Note FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND LOWER(Note) LIKE 'allow duplicate hold request%'";
	LogDebug(connection.QueryString);
	connection:Connect();
	local bypass = connection:ExecuteScalar();
	connection:Disconnect();
	
	if bypass ~= nil then
		ExecuteCommand("AddNote",{transactionNumber, "The check_allow_for_duplicate_requests_for_holds function found the note to allow for duplicate hold requests of the same title. Attempting to process transaction."});
		LogDebug("check_allow_for_duplicate_requests_for_holds > The check_allow_for_duplicate_requests_for_holds function found the note to allow for duplicate hold requests of the same title. Attempting to process transaction.");
		return true
	else
		LogDebug("check_allow_for_duplicate_requests_for_holds > The check_allow_for_duplicate_requests_for_holds function did not find a note to allow for duplicate hold requests of the same title.");
		return false
	end
end

function check_allow_for_duplicate_requests_for_loans()
	LogDebug("Initializing function check_allow_for_duplicate_requests_for_loans");
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT Note FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND LOWER(Note) LIKE 'allow duplicate loan request%'";
	LogDebug(connection.QueryString);
	connection:Connect();
	local bypass = connection:ExecuteScalar();
	connection:Disconnect();
	
	if bypass ~= nil then
		ExecuteCommand("AddNote",{transactionNumber, "The check_allow_for_duplicate_requests_for_loans function found the note to allow for duplicate loan requests of the same title. Attempting to process transaction."});
		LogDebug("check_allow_for_duplicate_requests_for_loans > The check_allow_for_duplicate_requests_for_loans function found the note to allow for duplicate loan requests of the same title. Attempting to process transaction.");
		return true
	else
		LogDebug("check_allow_for_duplicate_requests_for_loans > The check_allow_for_duplicate_requests_for_loans function did not find a note to allow for duplicate loan requests of the same title.");
		return false
	end
end

function myerrorhandler_retry( err )

-- This is the error handler for Borrowing HOLD Request Sender RETRY with Description value for 1 multivolume item
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);

   --LogDebug("ALMA BORROWING REQUEST SENDER build_request_retry ERROR");
   
	if err ~= nil then
		LogDebug("myerrorhandler_retry > Raw error is: " .. tostring(err));
		--if err.InnerException ~= nil then
		LogDebug('myerrorhandler_retry > HTTP Error: ' .. err.InnerException.Message);
		local responseStream = err.InnerException.Response:GetResponseStream();
		local reader = Types["System.IO.StreamReader"](responseStream);
		local responseText = reader:ReadToEnd();
		reader:Close();
		--LogDebug(responseText);
		local errorCode = responseText:match('errorCode>(.-)<'):gsub('(.-)>', '');
		local errorMessage = responseText:match('errorMessage>(.-)<'):gsub('(.-)>', '');
		LogDebug("myerrorhandler_retry > Found ALMA errorCode: " .. errorCode .. ": " .. errorMessage);
	
		LogDebug("myerrorhandler_retry > There was an error executing the ALMA BORROWING REQUEST SENDER build_hold_request_sender_retry function.");
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
			
						LogDebug("myerrorhandler_retry > The Alma error code for routing is: " .. Alma_error_code);
						LogDebug("myerrorhandler_retry > The transaction with the Alma error is being routed to: " .. second_split);
						ExecuteCommand("Route",{transactionNumber, second_split});
						break;
					end

				end
				if string.find(line_concatenator, errorCode) == nil then
					ExecuteCommand("AddNote",{transactionNumber, "Found ALMA Users API errorCode: " .. errorCode .. ": " .. errorMessage});
					ExecuteCommand("Route",{transactionNumber, Settings.ItemFailHoldRequestQueue});
					SaveDataSource("Transaction");
				end
			error_routing_list:close();
			end
		end
	end
end

function get_single_description_from_notes()
	LogDebug("Initializing function get_single_description_from_notes");
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT Note FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND Note LIKE 'ALMA BORROWING REQUEST SENDER: " .. Settings.AddonWorkerName .. ": Single Description Available%'";
	LogDebug(connection.QueryString);
	connection:Connect();
	local description = connection:ExecuteScalar();
	connection:Disconnect();
	
	LogDebug("The Description value is: " .. description);
	
	if description ~= nil then
		LogDebug("get_single_description_from_notes > The get_single_description_from_notes function found a note with a description value. Attempting to extract volume information.");
		local description_value = string.match(description, "%[(.-)%]");
		LogDebug("get_single_description_from_notes > Found description value.  Attempting to use [" .. description_value .. "] for description tag within the XML message for the transaction.");
		return description_value;
	else
		LogDebug("get_single_description_from_notes > The get_single_description_from_notes function did not find a note with a description.");
		return false;
	end
end

function build_hold_request_sender_retry()
LogDebug("Initializing function build_hold_request_sender");

local user = GetUserName()
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);
local ILLiad_Request_Type = GetFieldValue("Transaction", "RequestType");

if Settings.EnableSendingHoldRequests == true then
-- Get the user's matching pickup location and pickup location institution by using the sublibraries.txt crosswalk file	
local pickup_location_full = GetNVTGC()
local sublibraries = assert(io.open(AddonInfo.Directory .. "\\sublibraries.txt", "r"));
local pickup_location_type = "";
local pickup_location = "";
local first_split = "";
local second_split = "";
local templine = nil;
local found_pickup_location_full = false;
	if sublibraries ~= nil then
		for line in sublibraries:lines() do
			if string.find(line, pickup_location_full) then
				found_pickup_location_full = true;
				first_split,second_split = line:match("(.+),(.+)");
				pickup_location_library = second_split;
				pickup_location_institution = Settings.AlmaInstitutionCode;
				pickup_location_type = "LIBRARY";
				if pickup_location_library == "Home Delivery" then
				pickup_location_type = "USER_HOME_ADDRESS";
				end
				if pickup_location_library == "Office Delivery" then
				pickup_location_type = "USER_WORK_ADDRESS";
				end
				LogDebug("build_hold_request_sender_retry > The pick up location library is: " .. pickup_location_library);
				LogDebug("build_hold_request_sender_retry > The pick up location institution is: " .. pickup_location_institution);
				LogDebug("build_hold_request_sender_retry > The pick up location type is: " .. pickup_location_type);
    		end
  		end
		sublibraries:close();
   	end
	if found_pickup_location_full == false then
	pickup_location_library = "nothing";
	ExecuteCommand("AddNote",{transactionNumber_int, "From Alma Borrowing Request Sender: The ILLiad NVTGC for the user on this TN was not found in the Addon's sublibraries.txt file.  Please update the sublibraries.txt file, reinstall the Addon, and try again."});
	end
	
-- Assemble XML hold message to send to API

local note_for_alma = "From ILLiad TN: " .. transactionNumber_int .. " for RequestType: " .. ILLiad_Request_Type;

local multivolume_data = get_single_description_from_notes()

if multivolume_data ~= false then
local multivolume_XML_chunk = "<description>" .. multivolume_data .. "</description>";
hold_message = '<?xml version="1.0" encoding="ISO-8859-1"?><user_request><request_type>HOLD</request_type>' .. multivolume_XML_chunk .. '<pickup_location_type>' .. pickup_location_type .. '</pickup_location_type><pickup_location_library>' .. pickup_location_library .. '</pickup_location_library><pickup_location_institution>' .. Settings.AlmaInstitutionCode .. '</pickup_location_institution><comment>' .. note_for_alma .. '</comment></user_request>';
end
if multivolume_data == false then
LogDebug("Unable to find a single decription field for transaction within the TN notes.");
ExecuteCommand("AddNote",{transactionNumber_int, "Unable to determine multivolume information for resending the transaction with description field. Routing TN to multivolume review queue: " .. Settings.MultiVolumeRewiewQueue});
ExecuteCommand("Route",{transactionNumber_int, Settings.MultiVolumeRewiewQueue});
return true
end

--LogDebug(hold_message);
if Settings.UltimateDebug then
	ExecuteCommand("AddNote",{transactionNumber_int, "UltimateDebug > Alma API Hold Message: " .. hold_message});
end

-- Assemble URL for connecting to Users API
local alma_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=false&apikey=' .. Settings.AlmaUsersAPIKey;
local alma_url_for_message = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=false&apikey=YOUR_KEY'; 

if check_allow_duplicate_requests_for_holds == true then
local alma_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=true&apikey=' .. Settings.AlmaUsersAPIKey;
local alma_url_for_message = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=true&apikey=YOUR_KEY'; 
end

if Settings.UltimateDebug then
	ExecuteCommand("AddNote",{transactionNumber_int, "UltimateDebug > Alma API URL for Hold Message: " .. alma_url_for_message});
end
	
		LogDebug("build_hold_request_sender_retry > Hold Message prepared for sending: " .. hold_message);
		LogDebug("build_hold_request_sender_retry > Alma URL prepared for connection: " .. alma_url_for_message);
		LogDebug("build_hold_request_sender_retry > Creating web client for Alma HOLD message.");
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
       	webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("accept", "application/xml; charset=UTF-8");
		LogDebug("build_hold_request_sender_retry > Sending Hold Message to Alma Users API.");
				
		local responseString = webClient:UploadString(alma_url, hold_message);

		if string.find(responseString, "<user_request>") then
			LogDebug("build_hold_request_sender_retry > No Problems found in Alma Users HOLD API Response.");
			ExecuteCommand("Route",{transactionNumber_int, Settings.ItemSuccessHoldRequestQueue});
			ExecuteCommand("AddNote",{transactionNumber_int, "Alma API Response for HOLD received successfully"});
			--ExecuteCommand("AddNote",{transactionNumber_int, "Alma API Successful Response: " .. responseString});
			SaveDataSource("Transaction");	
			return true;
		end
	end 	
end -- end function


function description_lookup(MMSID)
LogDebug("Initializing function description_lookup");
hold_send_rerun_count = hold_send_rerun_count + 1;
if hold_send_rerun_count > 1 then
	LogDebug("description_lookup > The description lookup function already ran on this MMSID. Stopping Addon.");
else
--local MMSID = "990002882480204833";
	local currentTN = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

	local bibs_url = Settings.AlmaBaseURL .. "/bibs/" .. MMSID .. "/holdings/ALL/items?limit=100&offset=0&order_by=none&direction=desc&view=brief&apikey=" .. Settings.AlmaBibsAPIKey;

	local bibs_url_for_print = Settings.AlmaBaseURL .. "/bibs/" .. MMSID .. "/holdings/ALL/items?limit=100&offset=0&order_by=none&direction=desc&view=brief&apikey=YOUR_API_KEY";

	LogDebug("description_lookup > " .. bibs_url_for_print);

	LogDebug("description_lookup > Creating Bibs web client to lookup holdings for MMSID: " .. MMSID);
			local webClient = Types["WebClient"]();
			webClient.Headers:Clear();
			webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
			webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
			LogDebug("Sending MMSID to retrieve holdings from Bibs API.");
			local responseString = webClient:DownloadString(bibs_url);
			local item_count = 0;
			if string.find(responseString, 'item link') ~= nil then
			
			local item_tag_count = 0;
			for tags in string.gmatch(responseString, "<item link") do
				item_tag_count = item_tag_count + 1;
			end
			
			LogDebug("description_lookup > There were " .. tostring(item_tag_count) .. " <item link> tags found");

			if item_tag_count == 1 then
			local description_value = responseString:match('<description(.-)</description>'):gsub('(.-)>', ''); -- look for description tag value
				if description_value ~= "" then
					LogDebug("description_lookup > The item is showing a description of [" .. description_value .. "]");
					ExecuteCommand("AddNote",{transactionNumber_int, "ALMA BORROWING REQUEST SENDER: " .. Settings.AddonWorkerName .. ": Single Description Available: [" .. description_value .. "]"});
					LogDebug("description_lookup > Attempting to resend Hold Request with new description tag data");
					
					local messageSent4 = false;
					local response;
					
					messageSent4, response = pcall(build_hold_request_sender_retry);
			
						if (messageSent4 == false) then
							LogDebug('description_lookup > There was an error in the Alma_API from the build_request function. Sending to Error Handler.');
							return myerrorhandler_retry(response);		
						else		
						end
				end
			end
			if item_tag_count > 1 then
				ExecuteCommand("AddNote",{transactionNumber_int, "There were more than 1 <item link> tags in the Bibs API return. Sending TN to MultiVolume Review Queue: " .. Settings.MultiVolumeRewiewQueue .. ". Please add PID(s) to " .. Settings.ILLiadFieldToStorePIDs .. " field, remove processing note, and reroute TN to " .. Settings.ItemSearchQueue});
				LogDebug("description_lookup > There were more than 1 <item link> tags in the Bibs API return. Sending TN to MultiVolume Review Queue: " .. Settings.MultiVolumeRewiewQueue);
				ExecuteCommand("Route",{transactionNumber_int, Settings.MultiVolumeRewiewQueue});
				return false;
			end
		end
	end
end

function myerrorhandler2( err )

-- This is the error handler for the Borrowing Request Sender

	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);

   --LogDebug("ALMA BORROWING REQUEST SENDER build_hold_request ERROR");
   
	if err ~= nil then
		LogDebug("myerrorhandler2 > Raw error is: " .. tostring(err));
		LogDebug('myerrorhandler2 > HTTP Error: ' .. err.InnerException.Message);
		local responseStream = err.InnerException.Response:GetResponseStream();
		local reader = Types["System.IO.StreamReader"](responseStream);
		local responseText = reader:ReadToEnd();
		reader:Close();
		--LogDebug(responseText);
		local errorCode = responseText:match('errorCode>(.-)<'):gsub('(.-)>', '');
		local errorMessage = responseText:match('errorMessage>(.-)<'):gsub('(.-)>', '');
		LogDebug("myerrorhandler2 > Found ALMA errorCode from API for Borrowing Request: " .. errorCode .. ": " .. errorMessage);
	
		LogDebug("myerrorhandler2 > There was an error executing the ALMA BORROWING REQUEST SENDER build_request function.");
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
			
						LogDebug("myerrorhandler2 > The Alma error code for routing is: " .. Alma_error_code);
						LogDebug("myerrorhandler2 > The transaction with the Alma error is being routed to: " .. second_split);
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
		LogDebug("myerrorhandler > Raw error is: " .. tostring(err));
		--if err.InnerException ~= nil then
		LogDebug('myerrorhandler > HTTP Error: ' .. err.InnerException.Message);
		local responseStream = err.InnerException.Response:GetResponseStream();
		local reader = Types["System.IO.StreamReader"](responseStream);
		local responseText = reader:ReadToEnd();
		reader:Close();
		--LogDebug(responseText);
		local errorCode = responseText:match('errorCode>(.-)<'):gsub('(.-)>', '');
		local errorMessage = responseText:match('errorMessage>(.-)<'):gsub('(.-)>', '');
		LogDebug("myerrorhandler > Found ALMA errorCode: " .. errorCode .. ": " .. errorMessage);
	
		LogDebug("myerrorhandler > There was an error executing the ALMA BORROWING REQUEST SENDER build_hold_request function.");
		ExecuteCommand("AddNote",{transactionNumber, "Found ALMA Users HOLD Request API errorCode: " .. errorCode .. ": " .. errorMessage});
		SaveDataSource("Transaction");
		--ExecuteCommand("AddNote",{transactionNumber, responseText});
						
		if errorCode ~= nil then
			
			if errorCode == '401136' then
			ExecuteCommand("Route",{transactionNumber, Settings.ItemFailHoldRequestQueue});
			end
		
			if errorCode == '401122' then
				LogDebug("Found error code 401122. Attempting to add description tag.");
				if hold_send_rerun_count < 1 then
					description_lookup(MMSID)
				end
			end

			if errorCode == '4018992' then
				LogDebug("Found error code 4018992. Attempting to add description tag.");
				if hold_send_rerun_count < 1 then
					description_lookup = description_lookup(MMSID)
					LogDebug("myerrorhandler > The description lookup returned: " .. tostring(description_lookup));
					if description_lookup == false then
						return true;
					end
				end			
			end
					
			if errorCode ~= '401136' and errorCode ~= '401122' and errorCode ~= '4018992' then
						
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
				
							LogDebug("myerrorhandler > The Alma error code for routing is: " .. Alma_error_code);
							LogDebug("myerrorhandler > The transaction with the Alma error is being routed to: " .. second_split);
							ExecuteCommand("Route",{transactionNumber, second_split});
							break;
						end

					end
					
					if myPIDchecker == true then
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
					end
					if myPIDchecker == false then
						LogDebug("myerrorhandler > There was an error sending the PID.");
					end
				error_routing_list:close();
				end
			end			
		end
	end
end






function check_partners_list(partner)
    LogDebug("Initializing function check_partners_list")
    local currentTN = GetFieldValue("Transaction", "TransactionNumber")
    local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN)
    local found_partner = false
    local partners = assert(io.open(AddonInfo.Directory .. "\\partners.txt", "r"))
    if partners == nil then
        LogDebug("check_partners_list > The partners.txt file is empty.")
    end

    local alma_partner_code = ""
    local first_split = ""
    local second_split = ""
    local found_partner_code = false
    if partners ~= nil then
        for line in partners:lines() do
            first_split, second_split = line:match("([^,]+),([^,]+)")
            if first_split == partner then
                found_partner = true
                alma_partner_code = second_split
                LogDebug("check_partners_list > A matching partner was found on the partners.txt file: " .. alma_partner_code)
                ExecuteCommand("AddNote", {transactionNumber_int, "check_partners_list > The partner  [" .. partner .. "] is on the partners.txt file."})
                return alma_partner_code
            end
        end
        partners:close()
    end
    if found_partner == false then
        LogDebug("check_partners_list > There was not a matching item location found on the partners.txt file for " .. partner)
        return false
    end
end



-- Function to process the LendingString
function process_lending_string()
    LogDebug("Initializing function process_lending_string");

    -- Get the LendingString field
    local lendingstring = GetFieldValue("Transaction", "LendingString");

    if lendingstring ~= "" then
        -- Split the string and get the first symbol
        local first_symbol = string.match(lendingstring, '([^,]+)');

        if first_symbol and check_partners_list(first_symbol) then
            LogDebug("Match found on partners.txt: " .. first_symbol);
            return check_partners_list(first_symbol)
        end
    end

    LogDebug("No match found");
    return nil
end



function HandleContextProcessing()

	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local RequestType = GetFieldValue("Transaction", "RequestType");
	local ProcessType = GetFieldValue("Transaction", "ProcessType");
	local real_isbn = GetFieldValue("Transaction", "ISSN");

	if ProcessType == "Borrowing" then
		if RequestType == "Loan" then	
			LogDebug("Sleeping for 1 second");
			os.execute("sleep 1");
			LogDebug("HandleContextProcessing > Attempting to reset global variables");
			LogDebug("HandleContextProcessing > Current values before reset:  hold_send_rerun_count: " .. tostring(hold_send_rerun_count) .. ". check_allow_duplicate_requests_for_holds: " .. tostring(check_allow_duplicate_requests_for_holds) .. ". check_allow_duplicate_requests_for_loans: " .. tostring(check_allow_duplicate_requests_for_loans) .. ". check_user_has_current_hold: " .. tostring(check_user_has_current_hold) .. ". check_user_has_current_hold: " .. tostring(check_user_has_current_hold) .. ".");
			hold_send_rerun_count = 0;
			check_allow_duplicate_requests_for_holds = false;
			check_allow_duplicate_requests_for_loans = false;
			check_user_has_current_loan = false;
			check_user_has_current_hold = false;
			LogDebug("HandleContextProcessing > Reset values:  hold_send_rerun_count: " .. tostring(hold_send_rerun_count) .. ". check_allow_duplicate_requests_for_holds: " .. tostring(check_allow_duplicate_requests_for_holds) .. ". check_allow_duplicate_requests_for_loans: " .. tostring(check_allow_duplicate_requests_for_loans) .. ". check_user_has_current_hold: " .. tostring(check_user_has_current_hold) .. ". check_user_has_current_hold: " .. tostring(check_user_has_current_hold) .. ".");
			if rerun_checker() == false then
				local allow_duplicate_checker_holds = check_allow_for_duplicate_requests_for_holds()
				if allow_duplicate_checker_holds == true then
					check_allow_duplicate_requests_for_holds = true;
				end		
				local allow_duplicate_checker_loans = check_allow_for_duplicate_requests_for_loans()
				if allow_duplicate_checker_loans == true then
					check_allow_duplicate_requests_for_loans = true;
				end
				
				local pids = GetFieldValue("Transaction", Settings.ILLiadFieldToStorePIDs);
				LogDebug('The PIDs value from ' .. Settings.ILLiadFieldToStorePIDs .. ' is: [' .. pids .. ']');

				if pids ~= "" then
				LogDebug("HandleContextProcessing > Leaving Note: " .. Settings.AddonWorkerName .. " ran on this transaction.");
				ExecuteCommand("AddNote",{transactionNumber, "The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " ran on this transaction."});
					local i = "";
					local x = 0;
					local single_pid = "";
					local pids_split_result = splitString(pids)
					for i, single_pid in ipairs(pids_split_result) do
						LogDebug("Found PID count number " .. i .. " with PID value: " .. single_pid);
						x = x + 1;
					end 
								
					local messageSent = false;
					local response;
					
					for i, single_pid in ipairs(pids_split_result) do	
					
					send_pid_request = build_hold_request_sender_for_pid(i, #pids_split_result, single_pid)
					
					end
				end	
				
				if pids == "" then
					LogDebug("HandleContextProcessing > Leaving Note: " .. Settings.AddonWorkerName .. " ran on this transaction.");
					ExecuteCommand("AddNote", {transactionNumber, "The ALMA BORROWING REQUEST SENDER Addon: " .. Settings.AddonWorkerName .. " ran on this transaction."});
					
					local good_isbn = validate_isbn(real_isbn);
					LogDebug("Validate_ISBN function returned: " .. tostring(good_isbn));
					local OCLCNumberField = GetFieldValue("Transaction", "ESPNumber");
					
					if good_isbn == true or OCLCNumberField ~= "" then
						local messageSent, response = pcall(build_hold_request);
						if not messageSent then
							LogDebug('There was an error in the Alma_API from the build_hold_request function. Sending to error handler.');
							return myerrorhandler(response);
						else
							LogDebug('ALMA BORROWING REQUEST SENDER executed successfully.');
						end
					else
						local fixed_isbn = extract_isbn(real_isbn);
						LogDebug("Extract_ISBN returned: " .. tostring(fixed_isbn));
						
						if fixed_isbn ~= true and OCLCNumberField == "" then
							LogDebug("The transaction does not have a valid ISBN and the OCLC Number field is blank");
							ExecuteCommand("AddNote", {transactionNumber, "Alma Borrowing Request Sender > Unable to extract ISBN from [" .. real_isbn .. "] and the OCLC Number is blank"});
							ExecuteCommand("Route", {transactionNumber, Settings.NoISBNandNoOCLCNumberReviewQueue});
						elseif fixed_isbn == true or OCLCNumberField ~= "" then
							local messageSent2, response2 = pcall(build_hold_request);
							if not messageSent2 then
								LogDebug('There was an error in the Alma_API from the build_hold_request function with extracted ISBN. Sending to error handler.');
								return myerrorhandler(response2);
							else
								LogDebug('ALMA BORROWING REQUEST SENDER executed successfully.');
							end
						end
					end
				end
	
			if myPIDchecker == false then		
				local list_of_failed_PIDs = table.concat(myFailedPIDs, ", ");
				LogDebug("There was an issue sending Hold Request with PID(s): " .. list_of_failed_PIDs .. ".  Routing to failure queue: " .. Settings.ItemFailHoldRequestQueue);
				ExecuteCommand("AddNote",{transactionNumber, "There was an issue sending Hold Request with PID(s): " .. list_of_failed_PIDs .. ".  Routing to failure queue: " .. Settings.ItemFailHoldRequestQueue .. ". Check Transaction Notes."});
				local currentStatus = statusChecker()
				LogDebug("Stage 1 Checker for list_of_failed_PIDs array > The values are [" .. list_of_failed_PIDs .. "]");
				for i = #myFailedPIDs, 1, -1 do 
					table.remove(myFailedPIDs, i)
				end
				local list_of_failed_PIDs = table.concat(myFailedPIDs, ", ");
				LogDebug("Stage 2 Checker for list_of_failed_PIDs array > The values are [" .. list_of_failed_PIDs .. "]");
				myPIDchecker = true;
				LogDebug("The current Transaction Status is: " .. currentStatus);
				if currentStatus ~= Settings.ItemFailHoldRequestQueue then
					ExecuteCommand("Route",{transactionNumber, Settings.ItemFailHoldRequestQueue});
				end
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

function handleWebClientUpload(alma_url, hold_message)
    local webClient = Types["WebClient"]()
    webClient.Headers:Clear()
    webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8")
    webClient.Headers:Add("accept", "application/xml; charset=UTF-8")
    return webClient:UploadString(alma_url, hold_message)
end

function build_hold_request_sender_for_pid(i, x, single_pid)
    LogDebug("Initializing function build_hold_request_sender_for_pid for Borrowing Request");
	
	local user = GetUserName()

    LogDebug("build_hold_request_sender_for_pid > Attempting to send PID request: " .. i .. " of " .. x .. " using PID: " .. single_pid);

	local successful_send = true;
    local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(GetFieldValue("Transaction", "TransactionNumber"));
    local ILLiad_Request_Type = GetFieldValue("Transaction", "RequestType");

	local pickup_location_full = GetNVTGC()
	local sublibraries = assert(io.open(AddonInfo.Directory .. "\\sublibraries.txt", "r"));
	local pickup_location = "";
	local pickup_location_type = "";
	local first_split = "";
	local second_split = "";
	local templine = nil;
	local found_pickup_location_full = false;
		if sublibraries ~= nil then
			for line in sublibraries:lines() do
				if string.find(line, pickup_location_full) then
					found_pickup_location_full = true;
					first_split,second_split = line:match("(.+),(.+)");
					pickup_location_library = second_split;
					pickup_location_institution = Settings.AlmaInstitutionCode;
					pickup_location_type = "LIBRARY";
					if pickup_location_library == "Home Delivery" then
						pickup_location_type = "USER_HOME_ADDRESS";
					end
					if pickup_location_library == "Office Delivery" then
						pickup_location_type = "USER_WORK_ADDRESS";
					end
					LogDebug("build_hold_request_sender_for_pid > The pick up location library is: " .. pickup_location_library);
					LogDebug("build_hold_request_sender_for_pid > The pick up location institution is: " .. pickup_location_institution);
					LogDebug("build_hold_request_sender_for_pid > The pick up location type is: " .. pickup_location_type);
				end
			end
		sublibraries:close();
		if found_pickup_location_full == false then
			pickup_location_library = "nothing";
			ExecuteCommand("AddNote",{transactionNumber_int, "From Alma Borrowing Request Sender: The ILLiad NVTGC for the user on this TN was not found in the Addon's sublibraries.txt file.  Please update the sublibraries.txt file, reinstall the Addon, and try again."});	
			end
		end

        local note_for_alma = "Request " .. i .. " of " .. x .. " from ILLiad TN: " .. transactionNumber_int .. " for RequestType: " .. ILLiad_Request_Type;

        local hold_message = '<?xml version="1.0" encoding="ISO-8859-1"?><user_request><request_type>HOLD</request_type><pickup_location_type>' .. pickup_location_type .. '</pickup_location_type><pickup_location_library>' .. pickup_location_library .. '</pickup_location_library><pickup_location_institution>' .. Settings.AlmaInstitutionCode .. '</pickup_location_institution><comment>' .. note_for_alma .. '</comment></user_request>';

        if Settings.UltimateDebug then
            ExecuteCommand("AddNote", {transactionNumber_int, "UltimateDebug > Alma API Hold Message: " .. hold_message});
        end

        local alma_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&item_pid=' .. single_pid .. '&allow_same_request=false&apikey=' .. Settings.AlmaUsersAPIKey;
		local alma_url_for_message = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&item_pid=' .. single_pid .. '&allow_same_request=false&apikey=YOUR_KEY'; 
        LogDebug("build_hold_request_sender_for_pid > Hold Message prepared for sending: " .. hold_message);
        LogDebug("build_hold_request_sender_for_pid > Alma URL prepared for connection: " .. alma_url_for_message);

        LogDebug("build_hold_request_sender_for_pid > Creating web client for Alma HOLD message.");

        LogDebug("build_hold_request_sender_for_pid > Sending Hold Message to Alma Users API.");
        local messageSent, response = pcall(handleWebClientUpload, alma_url, hold_message);

        if not messageSent then
            LogDebug('build_hold_request_sender_for_pid > There was an error in the Alma_API from the build_hold_request_sender_for_pid function. Sending to error handler.');
            --LogDebug('Error Details: ' .. tostring(response));
			myPIDchecker = false;
			table.insert(myFailedPIDs,single_pid)
            return myerrorhandler(response);
        else
            LogDebug("No Problems found in Alma Users HOLD API Response.");
            ExecuteCommand("Route", {transactionNumber_int, Settings.ItemSuccessHoldRequestQueue});
            ExecuteCommand("AddNote", {transactionNumber_int, "Alma API Response for HOLD received successfully for PID: " .. single_pid});
            SaveDataSource("Transaction");
        end
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
local found_pickup_location_full = false;
	if sublibraries ~= nil then
		for line in sublibraries:lines() do
			if string.find(line, pickup_location_full) then
				found_pickup_location_full = true;
				first_split,second_split = line:match("(.+),(.+)");
				pickup_location_library = second_split;
				pickup_location_institution = Settings.AlmaInstitutionCode;
				pickup_location_type = "LIBRARY";
				if pickup_location_library == "Home Delivery" then
					pickup_location_type = "USER_HOME_ADDRESS";
				end
				if pickup_location_library == "Office Delivery" then
					pickup_location_type = "USER_WORK_ADDRESS";
				end
				LogDebug("build_request > The pick up location library is: " .. pickup_location_library);
				LogDebug("build_request > The pick up location institution is: " .. pickup_location_institution);
				LogDebug("build_request > The pick up location type is: " .. pickup_location_type);
    		end
  		end
  	sublibraries:close();
	if found_pickup_location_full == false then
    	pickup_location_library = "nothing";
		ExecuteCommand("AddNote",{transactionNumber_int, "From Alma Borrowing Request Sender: The ILLiad NVTGC for the user on this TN was not found in the Addon's sublibraries.txt file.  Please update the sublibraries.txt file, reinstall the Addon, and try again."});	
   		end
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
local matching_partner = process_lending_string()

local partner_xml = "";
if matching_partner ~= false then
	partner_xml = "<partner>" .. tostring(matching_partner) .. "</partner>";
end


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
	ml = ml .. partner_xml;
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
	
LogDebug("build_request > Alma Message: " .. ml);

-- Assemble URL for connecting to Users API
local alma_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/resource-sharing-requests?user_id_type=all_unique&override_blocks=true&apikey=' .. Settings.AlmaUsersAPIKey;
local alma_url_for_printing = Settings.AlmaBaseURL .. '/users/' .. user .. '/resource-sharing-requests?user_id_type=all_unique&override_blocks=true&apikey=YOUR_KEY';

LogDebug("The check_allow_duplicate_requests_for_loans value is set to: [" .. tostring(check_allow_duplicate_requests_for_loans) .. "]");

-- check to see if duplicate requests are allowed
if check_allow_duplicate_requests_for_loans == true then
	alma_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/resource-sharing-requests?user_id_type=all_unique&override_blocks=true&allow_same_request=true&apikey=' .. Settings.AlmaUsersAPIKey;
	alma_url_for_printing = Settings.AlmaBaseURL .. '/users/' .. user .. '/resource-sharing-requests?user_id_type=all_unique&override_blocks=true&allow_same_request=true&apikey=YOUR_KEY';
end
	
		--LogDebug("Borrowing Message prepared for sending: " .. ml);
		--LogDebug("Alma URL prepared for connection: " .. alma_url);
		LogDebug("build_request > Creating web client.");
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
       	webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("accept", "application/xml; charset=UTF-8");
		LogDebug("Sending Borrowing Message to Alma API using URL: " .. alma_url_for_printing);
			
		local responseString = webClient:UploadString(alma_url, ml);
		LogDebug("build_request > Alma API Server Response: " .. responseString);

		-- if there is "<user_request>" tag in the response, then it was Successful
        -- if there is not a "<user_request>" tag in the response, the Addon will handle the error in the myerrorhandler2() function
		if string.find(responseString, "<user_resource_sharing_request>") then
			LogDebug("build_request > No Problems found in Alma Users API Response.");
			ExecuteCommand("Route",{transactionNumber_int, Settings.ItemSuccessQueue});
			ExecuteCommand("AddNote",{transactionNumber_int, "Alma API Response for Alma Borrowing Request Sender received successfully"});
			--ExecuteCommand("AddNote",{transactionNumber_int, "Alma API Successful Response: " .. responseString});
			SaveDataSource("Transaction");	
			return true
		end
	
	end
	if Settings.EnableSendingBorrowingRequests == false then
	LogDebug("build_request > The setting: EnableSendingBorrowingRequests is set to false. A Borrowing Request was not sent from the Addon.");
	return true
	end
end

function check_excluder(shelving_location)
LogDebug("Initializing function check_excluder");
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);
local found_exclusion = false;
	local excluded_locations = assert(io.open(AddonInfo.Directory .. "\\excluded_locations.txt", "r"));
	if excluded_locations ~= nil then
		for line in excluded_locations:lines() do
			--LogDebug(line)
			--if line == shelving_location then
				--LogDebug("We have a match! [" .. shelving_location .. "]");
			--end
			if string.find(line, shelving_location) then
				LogDebug("check_excluder > The shelving location [" .. shelving_location .. "] is on the Exclude list.");
				ExecuteCommand("AddNote",{transactionNumber_int, "Message from check_excluder function: The shelving location [" .. shelving_location .. "] is on the Exclude list."});
				found_exclusion = true;
				return true;
			end

		end
	end
	if found_exclusion == false then
		LogDebug("check_excluder > There was not a matching item location found on the Exclude list.");
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
			if string.find(line, the_process_type) then
				local check_excluder_bypass = check_excluder_bypass()
				if not check_excluder_bypass then
					first_split,second_split = line:match("(.+),(.+)");
					local process_type_phrase = first_split;
					local process_type_routing_queue_name = second_split;
					LogDebug("check_process_type_router > The process type [" .. the_process_type .. "] is on the process_type_router.txt file.  Routing TN to " .. process_type_routing_queue_name);				
					ExecuteCommand("AddNote",{transactionNumber_int, "Message from check_process_type_router function: The process type [" .. the_process_type .. "] is on the process_type_router.txt file.  Routing TN to " .. process_type_routing_queue_name });
					ExecuteCommand("Route",{transactionNumber_int, process_type_routing_queue_name});
					return true;
				end
				if check_excluder_bypass then
					LogDebug("check_process_type_router > IGNORING. The process type [" .. the_process_type .. "] is on the process_type_router.txt file, but a bypass note was found on the TN.");
					return false;
				end	
			end

		end
	end
end

function check_item_process_type(MMSID)

local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

local bibs_url = Settings.AlmaBaseURL .. "/bibs/" .. MMSID .. "/holdings/ALL/items?limit=100&offset=0&order_by=none&direction=desc&view=brief&apikey=" .. Settings.AlmaBibsAPIKey;

local bibs_url_for_print = Settings.AlmaBaseURL .. "/bibs/" .. MMSID .. "/holdings/ALL/items?limit=100&offset=0&order_by=none&direction=desc&view=brief&apikey=YOUR_API_KEY";

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
	
	
-- Function to remove punctuation from a string local 
function removePunctuation(str) 
	return str:gsub("%p", "") 
end 

-- Function to convert a string to lowercase 
function toLowerCase(str) 
	return str:lower() 
end

-- Function to check if the cleaned strings are equal 
function checkStringsEqual(s1, s2) 
	return s1 == s2
end

-- Function to parse XML and find the 'title' tags 
function findTitleTags(xml) 
	local titles = {} 
	-- clear titles table in case there is anything left behind from a previous run
	for i = #titles, 1, -1 do 
		table.remove(titles, i)
	end	
	
	for title in xml:gmatch("<title>(.-)</title>") do 
		table.insert(titles, title) 
	end 
	return titles 
end

-- Check if any title in the XML matches "Mia Mayhem and the cat burglar" 
function checkTitleInXML(xml, targetTitle) 
	local titles = findTitleTags(xml) 
	local cleanedTargetTitle = toLowerCase(removePunctuation(targetTitle)) 
	for _, title in ipairs(titles) do 
		local cleanedTitle = toLowerCase(removePunctuation(title)) 
		if checkStringsEqual(cleanedTitle, cleanedTargetTitle) then 
			return title	
		end 
	end 
	return false 
end
	
function check_user_loans(MMSID_value)
LogDebug("Initializing function check_user_loans");
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

local MMSID = MMSID_value;
LogDebug("check_user_loans > The check_user_loans MMSID is: [" .. MMSID .. "]");

local user = GetUserName()

		local user_loans_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/loans?user_id_type=all_unique&limit=100&offset=0&order_by=id&direction=ASC&loan_status=Active&apikey=' .. Settings.AlmaUsersAPIKey;
		local user_loans_url_for_print = Settings.AlmaBaseURL .. '/users/' .. user .. '/loans?user_id_type=all_unique&limit=100&offset=0&order_by=id&direction=ASC&loan_status=Active&apikey=YOUR_KEY';
        LogDebug("check_user_loans > Assembling User Loans Lookup URL: " .. user_loans_url_for_print);
		LogDebug("check_user_loans > Creating web client.");
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
		webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
		LogDebug("check_user_loans > Retrieving User Requests using Alma Users API.");
		local responseString = webClient:DownloadString(user_loans_url);
		--LogDebug(responseString);
		
		LogDebug("check_user_loans > Attempting TN title match on current loans");
		local targetTitle = GetFieldValue("Transaction", "LoanTitle");
		local result = checkTitleInXML(responseString, targetTitle);
		if result ~= false then
			LogDebug("check_user_loans > The requested title: [" .. targetTitle .. "] matches this title in the user's loans: [" .. tostring(result) .. "]");
			ExecuteCommand("AddNote",{transactionNumber_int, "The requested title: [" .. targetTitle .. "] matches this title in the user's loans: [" .. tostring(result) .. "]. Routing to Failure queue."});
			check_user_has_current_loan = true;
			if Settings.ItemFailQueue ~= "" then
				ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
			end
			if Settings.ItemFailQueue == "" and Settings.ItemFailHoldRequestQueue ~= "" then
				ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
			end		
			return true
		end

		if result == false then
			LogDebug("check_user_loans > There was no matching title found in the user's loans");
		end
		
		
		if string.find(responseString, MMSID) then
			local Requested_MMSID = responseString:match('<mms_id>' .. MMSID .. '</mms_id>');
		
			if Requested_MMSID ~= nil then
			LogDebug("check_user_loans > The user has a duplicate request already on Loan. Stopping Alma Borrowing Request Sender Addon.");
			
			local currentTN = GetFieldValue("Transaction", "TransactionNumber");
			local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);
			
			ExecuteCommand("AddNote",{transactionNumber_int, "The user has a duplicate request already on Loan. Stopping Alma Borrowing Request Sender Addon."});
		
				if Settings.ItemFailHoldRequestQueue ~= "" then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
					check_user_has_current_loan = true;
					return true;
				end
				if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
					check_user_has_current_loan = true;
					return true;
				end		
		
			end
		end
		if not string.find(responseString, MMSID) then
			LogDebug("check_user_loans > The user does not have a duplicate request already on Loan. Continue on.");
			return false;
		end
end	

function check_user_holds(MMSID_value)
LogDebug("Initializing function check_user_holds");
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

local MMSID = MMSID_value;
LogDebug("check_user_holds > The check_user_holds MMSID is: [" .. MMSID .. "]");

local user = GetUserName()


		local user_holds_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?request_type=HOLD&user_id_type=all_unique&limit=100&offset=0&status=active&apikey=' .. Settings.AlmaUsersAPIKey;
		local user_holds_url_for_print = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?request_type=HOLD&user_id_type=all_unique&limit=100&offset=0&status=active&apikey=YOUR_KEY';
        LogDebug("check_user_holds > Assembling User Hold Request Lookup URL: " .. user_holds_url_for_print);
		LogDebug("check_user_holds > Creating web client.");
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
		webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
		LogDebug("check_user_holds > Retrieving User Holds using Alma Users API.");
		local responseString = webClient:DownloadString(user_holds_url);
		--LogDebug(responseString);

		LogDebug("check_user_holds > Attempting TN title match on current holds");
		local targetTitle = GetFieldValue("Transaction", "LoanTitle");
		local result = checkTitleInXML(responseString, targetTitle);
		if result ~= false then
			LogDebug("check_user_holds > The requested title: [" .. targetTitle .. "] matches this title in the user's holds: [" .. tostring(result) .. "]");
			ExecuteCommand("AddNote",{transactionNumber_int, "The requested title: [" .. targetTitle .. "] matches this title in the user's holds: [" .. tostring(result) .. "]. Routing to Failure queue."});
			check_user_has_current_hold = true;
			if Settings.ItemFailHoldRequestQueue ~= "" then
				ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
			end
			if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
				ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
			end		
			return true
		end

		if result == false then
			LogDebug("check_user_holds > There was no matching title found in the user's holds");
		end
		
		if string.find(responseString, MMSID) then
			local Requested_MMSID = responseString:match('<mms_id>' .. MMSID .. '</mms_id>');
		
			if Requested_MMSID ~= nil then
			LogDebug("check_user_holds > The user has a duplicate request already on Hold or In Process. Stopping Alma Borrowing Request Sender Addon.");
			
			local currentTN = GetFieldValue("Transaction", "TransactionNumber");
			local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);
			
			ExecuteCommand("AddNote",{transactionNumber_int, "The user has a duplicate request already on hold or in process. Stopping Alma Borrowing Request Sender Addon."});
		
				if Settings.ItemFailHoldRequestQueue ~= "" then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
					check_user_has_current_hold = true;
					return true;
				end
				if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
					check_user_has_current_hold = true;
					return true;
				end		
		
			end
		end
		if not string.find(responseString, MMSID) then
			LogDebug("check_user_holds > The user does not have a duplicate request already on hold or in process. Continue on.");
			return false;
		end
end	

function build_hold_request_sender(MMSID)
LogDebug("Initializing function build_hold_request_sender");

local user = GetUserName()
local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);
local ILLiad_Request_Type = GetFieldValue("Transaction", "RequestType");

if Settings.EnableSendingHoldRequests == true then
-- Get the user's matching pickup location and pickup location institution by using the sublibraries.txt crosswalk file	
local pickup_location_full = GetNVTGC()
local sublibraries = assert(io.open(AddonInfo.Directory .. "\\sublibraries.txt", "r"));
local pickup_location_type = "";
local pickup_location = "";
local first_split = "";
local second_split = "";
local templine = nil;
local found_pickup_location_full = false;
	if sublibraries ~= nil then
		for line in sublibraries:lines() do
			if string.find(line, pickup_location_full) then
				found_pickup_location_full = true;
				first_split,second_split = line:match("(.+),(.+)");
				pickup_location_library = second_split;
				pickup_location_institution = Settings.AlmaInstitutionCode;
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
    		end
  		end
		sublibraries:close();
   	end
	if found_pickup_location_full == false then
	pickup_location_library = "nothing";
	ExecuteCommand("AddNote",{transactionNumber_int, "From Alma Borrowing Request Sender: The ILLiad NVTGC for the user on this TN was not found in the Addon's sublibraries.txt file.  Please update the sublibraries.txt file, reinstall the Addon, and try again."});
	end
	
-- Assemble XML hold message to send to API

local note_for_alma = "From ILLiad TN: " .. transactionNumber_int .. " for RequestType: " .. ILLiad_Request_Type;

local hold_message = '<?xml version="1.0" encoding="ISO-8859-1"?><user_request><request_type>HOLD</request_type><pickup_location_type>' .. pickup_location_type .. '</pickup_location_type><pickup_location_library>' .. pickup_location_library .. '</pickup_location_library><pickup_location_institution>' .. pickup_location_institution .. '</pickup_location_institution><comment>' .. note_for_alma .. '</comment></user_request>';

--LogDebug(hold_message);
if Settings.UltimateDebug then
	ExecuteCommand("AddNote",{transactionNumber_int, "UltimateDebug > Alma API Hold Message: " .. hold_message});
end

-- Assemble URL for connecting to Users API
local alma_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=false&apikey=' .. Settings.AlmaUsersAPIKey;
local alma_url_for_message = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=false&apikey=YOUR_KEY'; 

if check_allow_duplicate_requests_for_holds == true then
local alma_url = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=true&apikey=' .. Settings.AlmaUsersAPIKey;
local alma_url_for_message = Settings.AlmaBaseURL .. '/users/' .. user .. '/requests?user_id_type=all_unique&mms_id=' .. MMSID .. '&allow_same_request=true&apikey=YOUR_KEY'; 
end

if Settings.UltimateDebug then
	ExecuteCommand("AddNote",{transactionNumber_int, "UltimateDebug > Alma API URL for Hold Message: " .. alma_url_for_message});
end
	
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
					MMSID = ava_blocks:match('<subfield code="0">(.-)<'):gsub('(.-)>', ''); -- look for MMSID
					LogDebug("analyze_ava_tag > MMSID: " .. MMSID);		
					local mmsid_list = MMSID .. "," .. mmsid_list;
					-------------CHECKING USER'S CURRENT LOANS-------------
					if check_allow_duplicate_requests_for_holds == true then
						LogDebug("analyze_ava_tag > The user is allowed to place duplicate hold requests. Skipping check_user_loans function and check_user_holds function");
					else
						if check_user_loans(MMSID) then
							LogDebug("analyze_ava_tag > the check_user_loans function returned a duplicate active loan.");
							return false;
						end		
						-------------CHECKING USER'S CURRENT HOLDS-------------
						if check_user_holds(MMSID) then
							LogDebug("analyze_ava_tag > the check_user_holds function returned a duplicate active hold.");
							return false;
						end	
					end
					-------------DETERMINING AVAILABILITY-------------
					local availability_message = ava_blocks:match('<subfield code="e">(.-)<'):gsub('(.-)>', ''); -- look for availability in subfield e
					LogDebug("analyze_ava_tag > availability_message: " .. availability_message);
					if availability_message == "unavailable" or availability_message == "Unavailable" then
						use_record = false;
						is_item_available = false;
						LogDebug("analyze_ava_tag > The MMSID: " .. MMSID .. " is showing as " .. availability_message);
						LogDebug("analyze_ava_tag > Preparing to connect to Bibs API to determine if there is a process_type (e.g., MISSING)");
						if check_item_process_type(MMSID) then		
							return false;
						end
					
					end
					if availability_message == "Available" or availability_message == "available" then
						LogDebug("analyze_ava_tag > The MMSID: " .. MMSID .. " is showing as " .. availability_message);
						is_item_available = true;
					end
					-------------DETERMINING LOCATION-------------
					local shelving_location = "";
					if string.find(ava_blocks, '<subfield code="c">') ~= nil then -- if the block has a location (in subfield m) then get location, else skip location retrieval
						shelving_location = ava_blocks:match('<subfield code="c">(.-)<'):gsub('(.-)>', '');			
						LogDebug("analyze_ava_tag > Location: " .. shelving_location);
						local check_excluder_return = check_excluder(shelving_location)
						if check_excluder_return then
							local check_excluder_bypass = check_excluder_bypass()
							if not check_excluder_bypass then
								is_location_permitted_for_use = false;
								use_record = false;
								LogDebug("analyze_ava_tag > [The location: [" .. shelving_location .. "] is on the exclude list. Skipping record.");
							end
							if check_excluder_bypass then
								is_location_permitted_for_use = true;
								use_record = true;
								LogDebug("analyze_ava_tag > [The location: [" .. shelving_location .. "] is on the exclude list, but there is a TN note to bypass excluded locations. Attempting to use record.");
							end
						end
						if not check_excluder_return then
							is_location_permitted_for_use = true;
							LogDebug("analyze_ava_tag > This location permitted for Holds and Borrowing: [" .. shelving_location .. "]");							
							if is_item_available then
								use_record = true;
							end
						end			
					end

					if string.find(ava_blocks, '<subfield code="c">') == nil then  -- if it cannot find subfield c, leave a note
						LogDebug("analyze_ava_tag > From Alma SRU > Cannot Determine Location.  The <subfield code='c'> is blank in the AVE tag from the SRU return.");
						is_location_permitted_for_use = true;
					end	

					if is_item_available and is_location_permitted_for_use then
						is_record_found = true;
						LogDebug("analyze_ava_tag > Found available item for MMSID: " .. MMSID);
						if build_hold_request_sender(MMSID) then
							return true;
						end
					end				
				end --if the block has an MMSID then
			end -- for loop
			if use_record == false then
			LogDebug("analyze_ava_tag > No Available items found for MMSID record(s): " .. mmsid_list:sub(1, -2));
				if is_location_permitted_for_use == false then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemInExcludedLocationNeedsReviewQueue});
					ExecuteCommand("AddNote",{transactionNumber_int,"The location is on the exclude list. Routing to Review Queue."});
					return false;
				end
				if is_location_permitted_for_use == true then
					if Settings.EnableSendingBorrowingRequests == true then
					LogDebug("analyze_ava_tag > The item is currently checked out.");
						--build_request()
						return false;
					end
					if Settings.EnableSendingBorrowingRequests == false then
						LogDebug("analyze_ava_tag > EnableSendingHoldRequests is set to false and there are no available items for a Hold Request. Routing TN to failure queue.");
						ExecuteCommand("AddNote",{transactionNumber_int,"The item is currently checked out. Sending Borrowing Requests is disabled in the config.  Routing to failure queue."});
						if Settings.ItemFailHoldRequestQueue ~= "" then
							ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
							return false;
						end
						if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
							ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
							return false;
						end		
					end
				end				
			end
		end -- if AVA tag		
		if string.find(responseString, '<datafield ind1=" " ind2=" " tag="AVA">') == nil then
		LogDebug("The analyze_ava_tag function did not find an AVA tag within the SRU Lookup");
		return false;
		end
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
			for ave_blocks in string.gmatch(responseString, '<datafield ind1=" " ind2=" " tag="AVE">(.-)</datafield>') do -- for every AVE tag block that has a record with an 856, do the following
			if Settings.UltimateDebug then
				LogDebug(ave_blocks);
			end
				if string.find(ave_blocks, '<subfield code="0">') ~= nil then  --if the block has an MMSID then
					MMSID = ave_blocks:match('<subfield code="0">(.-)<'):gsub('(.-)>', ''); -- look for MMSID
					LogDebug("analyze_ave_tag > MMSID: " .. MMSID);		
					local mmsid_list = MMSID .. "," .. mmsid_list;
					-------------DETERMINING AVAILABILITY-------------
					local availability_message = ave_blocks:match('<subfield code="e">(.-)<'):gsub('(.-)>', ''); -- look for availability in subfield e
					LogDebug("analyze_ave_tag > availability_message: " .. availability_message);
					if availability_message == "unavailable" or availability_message == "Unavailable" then
						use_record = false;
						is_item_available = false;
						LogDebug("analyze_ave_tag > The MMSID: " .. MMSID .. " is showing as " .. availability_message);
					end
					if availability_message == "Available" or availability_message == "available" then
						is_item_available = true;
						LogDebug("analyze_ave_tag > The MMSID: " .. MMSID .. " is showing as " .. availability_message);
					end
					-------------DETERMINING LOCATION-------------
					local shelving_location = "";
					if string.find(ave_blocks, '<subfield code="m">') ~= nil then -- if the block has a location (in subfield m) then get location, else skip location retrieval
						shelving_location = ave_blocks:match('<subfield code="m">(.-)<'):gsub('(.-)>', '');			
						LogDebug("analyze_ave_tag > Location: " .. shelving_location);
						local check_excluder_return = check_excluder(shelving_location)
						if check_excluder_return then
							local check_excluder_bypass = check_excluder_bypass()
							if not check_excluder_bypass then
								is_location_permitted_for_use = false;
								use_record = false;
								LogDebug("analyze_ave_tag > [The location: [" .. shelving_location .. "] is on the exclude list. Skipping record.");
							end
							if check_excluder_bypass then
								is_location_permitted_for_use = true;
								use_record = true;
								LogDebug("analyze_ave_tag > [The location: [" .. shelving_location .. "] is on the exclude list, but there is a TN note to bypass excluded locations. Attempting to use record.");
							end
						end
						if not check_excluder_return then
						is_location_permitted_for_use = true;
						LogDebug("analyze_ave_tag > This location permitted for Holds and Borrowing: [" .. shelving_location .. "]");
							if is_item_available then
								use_record = true;	
							end
						end			
					end
					if string.find(ave_blocks, '<subfield code="m">') == nil then  -- if it cannot find subfield m, leave a note
						LogDebug("analyze_ave_tag > From Alma SRU > Cannot Determine Location.  The <subfield code='m'> is blank in the AVE tag from the SRU return.");
						is_location_permitted_for_use = true;
					end	
									
					if is_item_available and is_location_permitted_for_use then
							is_record_found = true;
							LogDebug("analyze_ave_tag > Attempting to set ILLiad Field: " .. Settings.ILLiadFieldforElectronicItemURL .. " with MMSID: " .. MMSID);
							local primo_permalink = Settings.PrimoPermalinkPrefix .. MMSID;
							ExecuteCommand("AddNote",{transactionNumber_int, "Alma Borrowing Request Sender: Local Electronic item availablity at: " .. primo_permalink});
							LogDebug("analyze_ave_tag > Local Electronic item availablity at: " .. primo_permalink);
							SetFieldValue("Transaction", Settings.ILLiadFieldforElectronicItemURL, primo_permalink);	
							SaveDataSource("Transaction");
							ExecuteCommand("Route",{transactionNumber_int, Settings.ElectronicItemSuccessQueue});		
							return true;
					end		
				end --if the block has an MMSID then
			end -- for loop
			if use_record == false then
			LogDebug("analyze_ave_tag > No Available items found for MMSID record(s): " .. mmsid_list:sub(1, -2));
				if is_location_permitted_for_use == false then
					ExecuteCommand("Route",{transactionNumber_int, Settings.ItemInExcludedLocationNeedsReviewQueue});
					ExecuteCommand("AddNote",{transactionNumber_int,"The location is on the exclude list. Routing to Review Queue."});
					return false;
				end
				if is_location_permitted_for_use == true then
					if Settings.EnableSendingBorrowingRequests == true then
					LogDebug("analyze_ave_tag > The item is currently checked out.");
						--build_request()
						return false;
					end
					if Settings.EnableSendingBorrowingRequests == false then
						LogDebug("analyze_ave_tag > EnableSendingHoldRequests is set to false and there are no available items for a Hold Request. Routing TN to failure queue.");
						ExecuteCommand("AddNote",{transactionNumber_int,"The item is currently checked out. Sending Borrowing Requests is disabled in the config.  Routing to failure queue."});
						if Settings.ItemFailHoldRequestQueue ~= "" then
							ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
							return false;
						end
						if Settings.ItemFailHoldRequestQueue == "" and Settings.ItemFailQueue ~= "" then
							ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailQueue});
							return false;
						end		
					end
				end
			end	
	end -- if AVE tag
		if string.find(responseString, '<datafield ind1=" " ind2=" " tag="AVE">') == nil then
		LogDebug("The analyze_ave_tag function did not find an AVE tag within the SRU Lookup");
		return false;
		end
end -- function

function build_hold_request()
LogDebug("Initializing function build_hold_request");

if Settings.EnableSendingHoldRequests == false then
	if Settings.EnableSendingBorrowingRequests == true then
		LogDebug("The setting EnableSendingHoldRequests is set to false and EnableSendingBorrowingRequests is set to true.  Attempting to send Borrowing request.");
		build_request()
	end
	if Settings.EnableSendingBorrowingRequests == false then
	LogDebug("The settings: EnableSendingHoldRequests and EnableSendingBorrowingRequests are set to false. One of these settings must be set to true for the Addon to function.");
	return true;
	end
end

if Settings.EnableSendingHoldRequests == true then
LogDebug("The setting EnableSendingHoldRequests is set to true.  Executing build_hold_request function.");

local currentTN = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber_int = luanet.import_type("System.Convert").ToDouble(currentTN);

local isbn = GetFieldValue("Transaction", "ISSN");
local oclc_number = GetFieldValue("Transaction", "ESPNumber");

local used_oclc_number = false;
local used_isbn = false;

local sru_url = "";
local records_found = "";
local responseString = "";

local use_password = false;
local password_and_key = "";

local base64mix = "";

if Settings.SRULookupUsername ~= "" and Settings.SRULookupPassword ~= "" then
		password_and_key = Settings.SRULookupUsername .. ":" .. Settings.SRULookupPassword;
		base64mix = to_base64(password_and_key)
		--LogDebug("Base64 mix is: " ..  base64mix);
		use_password = true;
end

if isbn == "" and oclc_number == "" then
	LogDebug("build_hold_request > No ISBN or OCLC Number found in Transaction.  Please add the ISBN or OCLC Number and reprocess Transasction.");
	ExecuteCommand("Route",{transactionNumber_int, Settings.NoISBNandNoOCLCNumberReviewQueue});
	return true;
end

local last_piece_of_Full_Alma_URL = string.sub(Settings.FullAlmaURL, -3);
if last_piece_of_Full_Alma_URL ~= "com" then
	ExecuteCommand("AddNote",{transactionNumber_int,"ERROR: Please update your Addon config value for FullAlmaURL.  Your FullAlmaURL should end in .com without a slash at the end of the URL."});
	LogDebug("ERROR: Please update your Addon config value for FullAlmaURL.  Your FullAlmaURL should end in .com without a slash at the end of the URL.");
end

if oclc_number ~= "" then
	sru_url = Settings.FullAlmaURL .. "/view/sru/" .. Settings.AlmaInstitutionCode .. "?version=1.2&operation=searchRetrieve&recordSchema=marcxml&query=alma.oclc_control_number_035_a=" .. oclc_number .. "&maximumRecords=50";
	used_oclc_number = true;
end

if isbn ~= "" then 
	sru_url = Settings.FullAlmaURL .. "/view/sru/" .. Settings.AlmaInstitutionCode .. "?version=1.2&operation=searchRetrieve&recordSchema=marcxml&query=alma.isbn=" .. isbn .. "&maximumRecords=50";
	used_isbn = true;
	used_oclc_number = false;
end

LogDebug(sru_url);
--if Settings.UltimateDebug then
--	ExecuteCommand("AddNote",{transactionNumber_int, "UltimateDebug > Alma SRU Lookup URL: " .. sru_url});
--end

	if used_isbn then
		LogDebug("build_hold_request > Creating SRU web client to lookup ISBN: " .. isbn);
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
		webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
		if use_password then
			webClient.Headers:Add("Authorization", "Basic " .. base64mix);
		end
		LogDebug("build_hold_request > Sending ISBN to Retrieve MMSID.");
		responseString = webClient:DownloadString(sru_url);
		--LogDebug(responseString);
		
		records_found = responseString:match('numberOfRecords>(.-)<'):gsub('(.-)>', '');
		--LogDebug(records_found);
	end
	
	if used_oclc_number then
		LogDebug("build_hold_request > Creating SRU web client to lookup OCLC Number: " .. oclc_number);
		local webClient = Types["WebClient"]();
		webClient.Headers:Clear();
		webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
		webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
		if use_password then
			webClient.Headers:Add("Authorization", "Basic " .. base64mix);
		end		
		LogDebug("build_hold_request > Sending OCLC Number to Retrieve MMSID.");
		responseString = webClient:DownloadString(sru_url);
		--LogDebug(responseString);	
		records_found = responseString:match('numberOfRecords>(.-)<'):gsub('(.-)>', '');
		--LogDebug(records_found);
	end
		
	if records_found ~= "0" then
		
		if used_isbn then
			LogDebug("build_hold_request > This number of records were found for ISBN " .. isbn .. ": " .. records_found);
		end
		if used_oclc_number then
			LogDebug("build_hold_request > This number of records were found for OCLC Number " .. oclc_number .. ": " .. records_found);
		end
		if Settings.EnableSendingHoldRequests == true then		
			if Settings.PreferElectronicOverPrintForHoldRequests == true then	
				local ava_lookup_fail = false;
				local ave_lookup_fail = false;
				local check_print_override = check_print_override()
				if check_print_override == true then
					ave_lookup_fail = true;
				end
				if not check_print_override then
					local analyze_ave_tag = analyze_ave_tag(responseString)
					 LogDebug("build_hold_request > analyze_ave_tag: " .. tostring(analyze_ave_tag));
					if analyze_ave_tag ~= true then
						LogDebug("build_hold_request > The AVE lookup did not return any electronic items to create a Hold request. Attempting AVA Lookup.");
						ave_lookup_fail = true;
					end
				end
				LogDebug("build_hold_request > ave_lookup_fail: " .. tostring(ave_lookup_fail));
				if ave_lookup_fail == true then
				local analyze_ava_tag = analyze_ava_tag(responseString)
					if analyze_ava_tag ~= true then
						LogDebug("build_hold_request > The AVA lookup did not return any available print items to create a Hold request.");
						--ExecuteCommand("AddNote",{transactionNumber_int,"The AVA lookup did not return any available print items to create a Hold request."});
						ava_lookup_fail = true;
					end
				end
				if ava_lookup_fail == true then
					if ave_lookup_fail == true then
						if Settings.EnableSendingBorrowingRequests == true then
							if check_user_has_current_loan == false then
								if check_user_has_current_hold == false then
									LogDebug("build_hold_request E over P > The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Attempting to send Borrowing request.");
									ExecuteCommand("AddNote",{transactionNumber_int,"The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Attempting to send Borrowing request. Attempting to place borrowing request."});									
									build_request()
								end
							end
							if check_user_has_current_loan == false then
								if check_user_has_current_hold == true then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request E over P > The AVA and AVE lookup returned zero results, and the patron has the item on hold. However, there is a duplicate loan request override note. Attempting to place borrowing request.");
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request."});
										build_request()
									end
								end
							end
							if check_user_has_current_loan == true then
								if check_user_has_current_hold == false then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request E over P > The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request.");
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request."});
										build_request()
									end
								end
							end								
							if check_user_has_current_loan == true then
								if check_user_has_current_hold == true then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request E over P > The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request.");
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request."});
										build_request()
									end
								end
							end
						end
						
						if Settings.EnableSendingBorrowingRequests == false then
							if check_user_has_current_loan == false then
								if check_user_has_current_hold == false then
									LogDebug("build_hold_request E over P > The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue);
									ExecuteCommand("AddNote",{transactionNumber_int,"The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue});
									ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
								end
							end
							if check_user_has_current_loan == false then
								if check_user_has_current_hold == true then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request E over P > The AVA and AVE lookup returned zero results, and the patron has the item on hold. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue);
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue});
										ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
									end
								end
							end
							if check_user_has_current_loan == true then
								if check_user_has_current_hold == false then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request E over P > The AVA and AVE lookup returned zero results, and the patron has the item on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue);
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue});
										ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
									end
								end
							end								
							if check_user_has_current_loan == true then
								if check_user_has_current_hold == true then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request E over P > The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue);
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue});
										ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
									end
								end
							end
						end						
									
					end
				end
				
			end
			
			if Settings.PreferElectronicOverPrintForHoldRequests == false then	
				local ava_lookup_fail = false;
				local ave_lookup_fail = false;
				local check_electronic_override = check_electronic_override()
				if check_electronic_override == true then
					ava_lookup_fail = true;
				end
				if not check_electronic_override then
					local analyze_ava_tag = analyze_ava_tag(responseString)
					 LogDebug("build_hold_request > analyze_ava_tag: " .. tostring(analyze_ava_tag));
					if analyze_ava_tag ~= true then
						LogDebug("build_hold_request > The AVA lookup did not return any physical items to create a Hold request. Attempting AVE Lookup.");
						--ExecuteCommand("AddNote",{transactionNumber_int,responseString});
						ava_lookup_fail = true;
					end
				end
				LogDebug("build_hold_request > ava_lookup_fail: " .. tostring(ava_lookup_fail));
				if ava_lookup_fail == true then
					local analyze_ave_tag = analyze_ave_tag(responseString)
					if analyze_ave_tag ~= true then
						LogDebug("build_hold_request > The AVE lookup lookup did not return any electronic items to create a Hold request.");
						ExecuteCommand("AddNote",{transactionNumber_int,"The AVE lookup lookup did not return any electronic items to create a Hold request."});
						ave_lookup_fail = true;
						-- ExecuteCommand("AddNote",{transactionNumber_int,"From Alma Borrowing Request Sender: The AVA lookup and AVE lookup showed available records but did not return any available items to create a Hold request. Routing to: " .. Settings.ItemFailHoldRequestQueue});
						-- ExecuteCommand("AddNote",{transactionNumber_int,responseString});
						-- ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
					end
				end
				if ave_lookup_fail == true then
					if ave_lookup_fail == true then
						if Settings.EnableSendingBorrowingRequests == true then
							if check_user_has_current_loan == false then
								if check_user_has_current_hold == false then
									LogDebug("build_hold_request P over E > The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Attempting to send Borrowing request.");
									ExecuteCommand("AddNote",{transactionNumber_int,"The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Attempting to place borrowing request."});							
									build_request()
								end
							end
							if check_user_has_current_loan == false then
								if check_user_has_current_hold == true then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request P over E > The AVA and AVE lookup returned zero results, and the patron has the item on hold. However, there is a duplicate loan request override note. Attempting to place borrowing request.")
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request."});
										build_request()
									end
								end
							end
							if check_user_has_current_loan == true then
								if check_user_has_current_hold == false then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request P over E > The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request.")
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request."});
										build_request()
									end
								end
							end								
							if check_user_has_current_loan == true then
								if check_user_has_current_hold == true then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request P over E > The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request.");
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note. Attempting to place borrowing request."});
										build_request()
									end
								end
							end
						end
						
						
						if Settings.EnableSendingBorrowingRequests == false then
							if check_user_has_current_loan == false then
								if check_user_has_current_hold == false then
									LogDebug("build_hold_request P over E > The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue);
									ExecuteCommand("AddNote",{transactionNumber_int,"build_hold_request P over E > The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue});									
									ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
								end
							end
							if check_user_has_current_loan == false then
								if check_user_has_current_hold == true then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request P over E > The AVA and AVE lookup returned zero results, and the patron has the item on hold. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue);
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue});
										ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
									end
								end
							end
							if check_user_has_current_loan == true then
								if check_user_has_current_hold == false then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request P over E > The AVA and AVE lookup returned zero results, and the patron has the item on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue);
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue});
										ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
									end
								end
							end								
							if check_user_has_current_loan == true then
								if check_user_has_current_hold == true then
									if check_allow_duplicate_requests_for_loans == true then
										LogDebug("build_hold_request P over E > The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue);
										ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. Placing borrowing requests is not enabled. Routing to: " .. Settings.ItemFailHoldRequestQueue});
										ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});
									end
								end
							end
						end						
					
					end
				end
			end
		end
		
		if Settings.EnableSendingHoldRequests == false then
			LogDebug("The setting: EnableSendingHoldRequests is set to false. A Hold Request was not sent from the Addon.");
					if Settings.EnableSendingBorrowingRequests == true then
						if check_user_has_current_loan == false then
							if check_user_has_current_hold == false then
								LogDebug("build_hold_request No Holds Allowed > The AVE lookup and AVA lookup did not return any available items to create a Hold request. The user does not have an active hold or loan on the item. Attempting to send Borrowing request.");
								build_request()
							end
						end
						if check_user_has_current_loan == false then
							if check_user_has_current_hold == true then
								if check_allow_duplicate_requests_for_loans == true then
									LogDebug("build_hold_request No Holds Allowed > The AVA and AVE lookup returned zero results, and the patron has the item on hold. However, there is a duplicate loan request override note.  Attempting to place borrowing request.");
									ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
									build_request()
								end
							end
						end
						if check_user_has_current_loan == true then
							if check_user_has_current_hold == false then
								if check_allow_duplicate_requests_for_loans == true then
									LogDebug("build_hold_request No Holds Allowed > The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request.");
									ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
									build_request()
								end
							end
						end								
						if check_user_has_current_loan == true then
							if check_user_has_current_hold == true then
								if check_allow_duplicate_requests_for_loans == true then
									LogDebug("build_hold_request No Holds Allowed > The AVA and AVE lookup returned zero results, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request.");
									ExecuteCommand("AddNote",{transactionNumber_int,"The AVA and AVE lookup returned zero results, and the patron has the item on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
									build_request()
								end
							end
						end
					end
			if Settings.EnableSendingBorrowingRequests == false then
			LogDebug("The settings: EnableSendingHoldRequests and EnableSendingBorrowingRequests are set to false. One of these settings must be set to true for the Addon to function.");
			end
		end
	end -- if records found is not zero		

	if records_found == "0" then
	LogDebug("build_hold_request > There were zero results found in SRU Lookup. Determining if Borrowing is allowed.");
		if Settings.EnableSendingHoldRequests == true then
			if Settings.EnableSendingBorrowingRequests == false then
				LogDebug("build_hold_request zero records & No Borrowing Allowed > There are 0 local holdings and EnableSendingBorrowingRequests is set to false. Routing TN to: " .. Settings.ItemFailHoldRequestQueue);
				ExecuteCommand("AddNote",{transactionNumber_int,"There are 0 local holdings and EnableSendingBorrowingRequests is set to false. Routing TN to: " .. Settings.ItemFailHoldRequestQueue});
				ExecuteCommand("Route",{transactionNumber_int, Settings.ItemFailHoldRequestQueue});	
				return true
			end
			if Settings.EnableSendingBorrowingRequests == true then
			LogDebug("build_hold_request > There were zero results and Sending Borrowing Requests is enabled.");
				LogDebug("build_hold_request zero records > Performing user duplicate hold check");
				local failed_duplicate_hold_check = false;
				local check_duplicate_hold_title = check_user_holds("empty_hold_mmsid");
				if check_duplicate_hold_title ~= false then
					failed_duplicate_hold_check = true;
				end
				
				LogDebug("build_hold_request zero records > Performing user duplicate loan check");
				local failed_duplicate_loan_check = false;
				local check_duplicate_loan_title = check_user_loans("empty_loan_mmsid");
				if check_duplicate_loan_title ~= false then
					failed_duplicate_loan_check = true;
				end
						
				if failed_duplicate_hold_check == false then
					if failed_duplicate_loan_check == false then
						LogDebug("build_hold_request zero records > There are 0 local holdings. The user passed the duplicate holds and duplicate loans check. Attempting to send Borrowing request.");
						build_request()
					end
				end
				if failed_duplicate_hold_check == true then
					if failed_duplicate_loan_check == false then
						if check_allow_duplicate_requests_for_loans == true then
							LogDebug("build_hold_request zero records > There are 0 local holdings, and the patron has the item on hold. However, there is a duplicate loan request override note.  Attempting to place borrowing request.")
							ExecuteCommand("AddNote",{transactionNumber_int,"There are 0 local holdings, and the patron has the item on hold. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
							build_request()
						end
					end
				end
				if failed_duplicate_hold_check == false then
					if failed_duplicate_loan_check == true then
						if check_allow_duplicate_requests_for_loans == true then
							LogDebug("build_hold_request zero records > There are 0 local holdings, and the patron has the item on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request.")
							ExecuteCommand("AddNote",{transactionNumber_int,"There are 0 local holdings, and the patron has the item on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
							build_request()
						end
					end
				end
				if failed_duplicate_hold_check == true then
					if failed_duplicate_loan_check == true then
						if check_allow_duplicate_requests_for_loans == true then
							LogDebug("build_hold_request zero records > There are 0 local holdings, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request.")
							ExecuteCommand("AddNote",{transactionNumber_int,"There are 0 local holdings, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
							build_request()
						end
					end
				end				
			end			
		end
		
		if Settings.EnableSendingHoldRequests == false then
			LogDebug("The setting: EnableSendingHoldRequests is set to false. A Hold Request was not sent from the Addon.");
			if Settings.EnableSendingBorrowingRequests == true then
				LogDebug("build_hold_request zero records No Holds Only Borrowing > Performing user duplicate hold check");
				local failed_duplicate_hold_check = false;
					local check_duplicate_hold_title = check_user_holds("empty_hold_mmsid");
					if check_duplicate_hold_title ~= false then
						failed_duplicate_hold_check = true;
					end
				
				LogDebug("build_hold_request zero records No Holds Only Borrowing > Performing user duplicate loan check");
				local failed_duplicate_loan_check = false;
					local check_duplicate_loan_title = check_user_loans("empty_loan_mmsid");
					if check_duplicate_loan_title ~= false then
						failed_duplicate_loan_check = true;
					end
						
				if failed_duplicate_hold_check == false then
					if failed_duplicate_loan_check == false then
						LogDebug("build_hold_request zero records No Holds Only Borrowing > There are 0 local holdings. The use does not have an active hold or loan on the item. Attempting to send Borrowing request.");
						build_request()
					end
				end
				if failed_duplicate_hold_check == true then
					if failed_duplicate_loan_check == false then
						if check_allow_duplicate_requests_for_loans == true then
							LogDebug("build_hold_request zero records No Holds Only Borrowing > There are 0 local holdings, and the patron has the item on hold. However, there is a duplicate loan request override note.  Attempting to place borrowing request.")
							ExecuteCommand("AddNote",{transactionNumber_int,"There are 0 local holdings, and the patron has the item on hold. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
							build_request()
						end
					end
				end
				if failed_duplicate_hold_check == false then
					if failed_duplicate_loan_check == true then
						if check_allow_duplicate_requests_for_loans == true then
							LogDebug("build_hold_request zero records No Holds Only Borrowing > There are 0 local holdings, and the patron has the item on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request.")
							ExecuteCommand("AddNote",{transactionNumber_int,"There are 0 local holdings, and the patron has the item on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
							build_request()
						end
					end
				end
				if failed_duplicate_hold_check == true then
					if failed_duplicate_loan_check == true then
						if check_allow_duplicate_requests_for_loans == true then
							LogDebug("build_hold_request zero records No Holds Only Borrowing > There are 0 local holdings, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request.")
							ExecuteCommand("AddNote",{transactionNumber_int,"There are 0 local holdings, and the patron has the item on hold and on loan. However, there is a duplicate loan request override note.  Attempting to place borrowing request."});
							build_request()
						end
					end
				end				
			end	
			if Settings.EnableSendingBorrowingRequests == false then
			LogDebug("The settings: EnableSendingHoldRequests and EnableSendingBorrowingRequests are set to false. One of these settings must be set to true for the Addon to function.");
			return true
			end
		end
	end -- if records_found == "0"
	end -- if Settings.EnableSendingHoldRequests is set to true
end -- function
