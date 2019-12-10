# nagios-check_salesforce
Requires Salesforce DX (SFDX) CLI tool

Install sfdx

= Connect Org
* Login to your target Org
* run `sudo sfdx force:auth:device:login` to get an auth code
** Must be sudo because the tool establishes a port tunnel for some reason (Salesforce's fault, sorry)
* Go to https://login.salesforce.com/setup/connect
* Enter the auth code

This process can be repeated for multiple Orgs

usernames, tokens, orgids, etc are stored in ~/.sfdx -- run `sfdx force:org:list` to see the list.


