# Alma Borrowing Request Sender ILLiad Server Addon

Check out the Alma Borrowing Request Sender wiki for installation instructions:

https://github.com/Hypolymer/Alma_Borrowing_Request_Sender/wiki

This Server Addon was developed by: 
- Bill Jones (SUNY Geneseo)
- Tim Jackson (SUNY Libraries Shared Services)
- Angela Persico (University at Albany)

A few details about the ILLiad Addon:
- The purpose of this Addon is to send Borrowing requests from ILLiad to Alma, and Hold requests for owned items
- The Addon monitors RequestType: Loan in a configurable ILLiad queue for ProcessType: Borrowing
- For usernames, the Addon allows staff to select which field in the Users table to use. Potential options include Username, SSN, and email
- The Addon uses an Alma SRU Lookup to determine availability and to gather item information
- The Addon uses the Bibs API in order to lookup item process_type for unavailable items to determine if MISSING, IN BINDERY, in ILL, or another process_type
- The Addon uses the Users API 'Retrieve user loans' call to analyze active requests to sift out duplicate ILL requests
- The Addon sends a Hold request to Alma using the Users API 'Create user request' call
- The Addon sends an Borrowing request to Alma using the Users API 'Create user request for resource sharing' call

Text files contained in the Addon for configuration:
- The Addon uses a file called error_routing.txt to route specific API numerical errors to specific ILLiad queues
- The Addon uses a file called sublibraries.txt to crosswalk between the ILLiad user NVTGC code (Example: ILL) and Alma Pickup Location code (Example: GENMN)
- The Addon uses a file called process_type_router.txt to route specific process_type values (like MISSING, or IN BINDERY, or RESERVES) to specific queues
- The Addon uses a file called excluded_locations.txt to make specific shelving locations unavailable for Hold requests 
