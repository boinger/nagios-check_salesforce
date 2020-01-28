for X in `ls ~/.sfdx | grep json | grep -v key.json`; do ; done
./check_salesforce-soql.sh -u admin@icix.wawainc01 -Q SELECT Id, Name, icix_v1__Request__r.Name, icix_v1__Status__c FROM ICIX_V1__Requeue_Message__c WHERE icix_v1__Status__c = 'Open' ORDER BY CreatedDate ASC --nolimit -c 1
