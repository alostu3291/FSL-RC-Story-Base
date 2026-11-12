// Signs up a pest demo cast customer the way Inspect & Quote does: an inspection with findings, a
// priced quote whose plans start START_DAYS_AGO days ago, and the customer's Sign & Pay signature.
// Run through seed_rtk_demo_cast, which fills the %%%...%%% tokens and skips customers already quoted.

String accountName = '%%%ACCOUNT_NAME%%%';
String street = '%%%STREET%%%';
String phone = '%%%PHONE%%%';
Integer startDaysAgo = Integer.valueOf('%%%START_DAYS_AGO%%%');
List<Object> findings = (List<Object>) JSON.deserializeUntyped('%%%FINDINGS%%%');

Database.DMLOptions dml = new Database.DMLOptions();
dml.DuplicateRuleHeader.AllowSave = true;
List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
Account account;
if (accounts.isEmpty()) {
    account = new Account(
        Name = accountName,
        ShippingStreet = street, ShippingCity = 'Bloomingdale', ShippingState = 'IL',
        ShippingPostalCode = '60108', ShippingCountry = 'United States',
        BillingStreet = street, BillingCity = 'Bloomingdale', BillingState = 'IL',
        BillingPostalCode = '60108', BillingCountry = 'United States'
    );
    Database.insert(account, dml);
} else {
    account = accounts[0];
}
if ([SELECT COUNT() FROM Asset WHERE AccountId = :account.Id] > 0) {
    throw new IllegalArgumentException(accountName + ' already has plans. Archive the account or pick a new name.');
}
if ([SELECT COUNT() FROM RLM_RTK_Inspection__c WHERE Account__c = :account.Id AND Quote__c != null] > 0) {
    throw new IllegalArgumentException(accountName + ' already has a quote from an inspection.');
}
if ([SELECT COUNT() FROM Contact WHERE AccountId = :account.Id] == 0) {
    String first = accountName.substringBefore(' ');
    String last = accountName.contains(' ') ? accountName.substringAfter(' ') : accountName;
    Database.insert(new Contact(AccountId = account.Id, FirstName = first, LastName = last,
        Email = (first + '.' + last).toLowerCase().replaceAll('[^a-z.]', '') + '@example.com',
        Phone = String.isBlank(phone) ? null : phone), dml);
}

RLM_RTK_Inspection__c inspection = new RLM_RTK_Inspection__c(Account__c = account.Id, Status__c = 'In Progress');
insert inspection;
for (Object item : findings) {
    Map<String, Object> f = (Map<String, Object>) item;
    RLM_RTK_Inspection.FindingInput input = new RLM_RTK_Inspection.FindingInput();
    input.zone = (String) f.get('zone');
    input.pest = (String) f.get('pest');
    input.evidence = (String) f.get('evidence');
    input.severity = (String) f.get('severity');
    input.customerNote = (String) f.get('customerNote');
    input.internalNote = (String) f.get('internalNote');
    RLM_RTK_Inspection.saveFinding(inspection.Id, input);
}

RLM_RTK_FieldQuote.Request request = new RLM_RTK_FieldQuote.Request();
request.accountId = account.Id;
request.planSku = '%%%PLAN%%%';
request.propertyType = 'SingleFamily';
request.squareFootage = '%%%SQFT%%%';
request.severity = '%%%SEVERITY%%%';
request.includeMosquito = '%%%MOSQUITO%%%' == 'true';
request.includeTermite = '%%%TERMITE%%%' == 'true';
request.inspectionId = inspection.Id;
request.startDate = Date.today().addDays(-startDaysAgo);
RLM_RTK_FieldQuote.Response response = RLM_RTK_FieldQuote.createQuote(request);
if (response.success != true) {
    throw new IllegalArgumentException('Quote for ' + accountName + ' failed: ' + response.message);
}

Quote signed = new Quote(Id = response.quoteId, RLM_Demo_Signed_By__c = accountName,
    RLM_Demo_Signed_At__c = System.now(), RLM_Demo_Card_Last4__c = '4242', RLM_Demo_Card_Brand__c = 'Visa');
try {
    signed.Status = 'Approved';
    update signed;
} catch (DmlException statusNotAllowed) {
    signed.Status = null;
    update signed;
}
