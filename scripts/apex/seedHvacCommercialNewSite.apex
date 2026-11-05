// Idempotent Brightline Commercial "new building": Westfield Commons Office, the site Lakeshore
// Property Group buys mid-term and adds to its contract with an amendment (Add Site on the account).
// Run after seedHvacCommercialSites and after the contract is booked, so the contract quote doesn't
// include it. Same keys as the site fixture: Account.RLM_HVAC_Site_Code__c and Asset.SerialNumber.

// Site code => { name, site type, street, city, postal code }; HQ is listed so the site parents to it.
final Map<String, List<String>> SITES = new Map<String, List<String>>{
    'LPG-HQ' => new List<String>{ 'Lakeshore Property Group', 'Headquarters', '1 Lakeshore Plaza', 'Naperville', '60563' },
    'LPG-WFC' => new List<String>{ 'Westfield Commons Office', 'Office', '2500 W Diehl Rd', 'Naperville', '60563' }
};

// Site code => units as 'tons|install year|refrigerant|charge lb|make model'.
final Map<String, List<String>> UNIT_SPECS = new Map<String, List<String>>{
    'LPG-WFC' => new List<String>{
        '5|2018|R-410A|11|Carrier 48FC 5-ton', '7.5|2018|R-410A|17|Carrier 48FC 7.5-ton',
        '7.5|2018|R-410A|17|Carrier 48FC 7.5-ton', '10|2021|R-410A|23|Carrier 48FC 10-ton',
        '10|2021|R-410A|23|Carrier 48FC 10-ton', '15|2023|R-454B|32|Trane Precedent 15-ton'
    }
};

Id businessType;
for (RecordType rt : [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Business_Account' AND IsActive = true LIMIT 1]) {
    businessType = rt.Id;
}

Map<String, Account> accountByCode = new Map<String, Account>();
for (Account a : [SELECT Id, ParentId, RLM_HVAC_Site_Code__c FROM Account WHERE RLM_HVAC_Site_Code__c IN :SITES.keySet()]) {
    accountByCode.put(a.RLM_HVAC_Site_Code__c, a);
}
List<Account> accounts = new List<Account>();
for (String code : SITES.keySet()) {
    List<String> s = SITES.get(code);
    Account a = accountByCode.containsKey(code) ? accountByCode.get(code) : new Account(RLM_HVAC_Site_Code__c = code);
    a.Name = s[0];
    a.RLM_HVAC_Site_Type__c = s[1];
    a.BillingStreet = s[2];
    a.BillingCity = s[3];
    a.BillingState = 'IL';
    a.BillingPostalCode = s[4];
    a.BillingCountry = 'United States';
    a.ShippingStreet = s[2];
    a.ShippingCity = s[3];
    a.ShippingState = 'IL';
    a.ShippingPostalCode = s[4];
    a.ShippingCountry = 'United States';
    a.Phone = '(630) 555-0' + String.valueOf(100 + accounts.size());
    if (a.Id == null && businessType != null) {
        a.RecordTypeId = businessType;
    }
    accounts.add(a);
}
upsert accounts;
for (Account a : accounts) {
    accountByCode.put(a.RLM_HVAC_Site_Code__c, a);
}
Id hqId = accountByCode.get('LPG-HQ').Id;
List<Account> children = new List<Account>();
for (String code : SITES.keySet()) {
    Account a = accountByCode.get(code);
    if (code != 'LPG-HQ' && a.ParentId != hqId) {
        children.add(new Account(Id = a.Id, ParentId = hqId));
    }
}
update children;

// HQ contacts: the facility director signs, accounts payable gets the invoice.
Map<String, Contact> contactByEmail = new Map<String, Contact>();
for (Contact c : [SELECT Id, Email FROM Contact WHERE AccountId = :hqId]) {
    contactByEmail.put(c.Email, c);
}
List<Contact> contacts = new List<Contact>();
for (List<String> c : new List<List<String>>{
    new List<String>{ 'Renee', 'Castillo', 'Director of Facilities', 'renee.castillo@lakeshore.example.com' },
    new List<String>{ 'Accounts', 'Payable', 'Accounts Payable', 'ap@lakeshore.example.com' }
}) {
    if (!contactByEmail.containsKey(c[3])) {
        contacts.add(new Contact(AccountId = hqId, FirstName = c[0], LastName = c[1], Title = c[2], Email = c[3],
            Phone = '(630) 555-0100'));
    }
}
insert contacts;

// A Field Service Location per site with its visitor address, linked to the site account.
Map<String, Schema.Location> locationByName = new Map<String, Schema.Location>();
Set<String> siteNames = new Set<String>();
for (String code : SITES.keySet()) {
    if (code != 'LPG-HQ') {
        siteNames.add(SITES.get(code)[0]);
    }
}
for (Schema.Location l : [SELECT Id, Name, VisitorAddressId FROM Location WHERE Name IN :siteNames]) {
    locationByName.put(l.Name, l);
}
List<Schema.Location> newLocations = new List<Schema.Location>();
for (String name : siteNames) {
    if (!locationByName.containsKey(name)) {
        newLocations.add(new Schema.Location(Name = name, LocationType = 'Site', IsInventoryLocation = false, IsMobile = false));
    }
}
insert newLocations;
for (Schema.Location l : newLocations) {
    locationByName.put(l.Name, l);
}
List<Schema.Address> addresses = new List<Schema.Address>();
List<String> addressSites = new List<String>();
for (String code : SITES.keySet()) {
    List<String> s = SITES.get(code);
    Schema.Location l = locationByName.get(s[0]);
    if (l != null && l.VisitorAddressId == null) {
        addresses.add(new Schema.Address(ParentId = l.Id, LocationType = 'Site', AddressType = 'Shipping',
            Street = s[2], City = s[3], State = 'IL', PostalCode = s[4], Country = 'United States'));
        addressSites.add(s[0]);
    }
}
insert addresses;
List<Schema.Location> withAddress = new List<Schema.Location>();
for (Integer i = 0; i < addresses.size(); i++) {
    withAddress.add(new Schema.Location(Id = locationByName.get(addressSites[i]).Id, VisitorAddressId = addresses[i].Id));
}
update withAddress;

Set<String> linked = new Set<String>();
for (AssociatedLocation al : [SELECT ParentRecordId, LocationId FROM AssociatedLocation WHERE LocationId IN :new Map<Id, Schema.Location>(locationByName.values()).keySet()]) {
    linked.add(al.ParentRecordId + ':' + al.LocationId);
}
List<AssociatedLocation> links = new List<AssociatedLocation>();
for (String code : SITES.keySet()) {
    Schema.Location l = locationByName.get(SITES.get(code)[0]);
    Id accountId = accountByCode.get(code).Id;
    if (l != null && !linked.contains(accountId + ':' + l.Id)) {
        links.add(new AssociatedLocation(ParentRecordId = accountId, LocationId = l.Id, Type = 'Ship To'));
    }
}
insert links;

// Rooftop units as customer equipment, one Asset each, keyed on SerialNumber.
Map<String, Asset> assetBySerial = new Map<String, Asset>();
for (Asset a : [SELECT Id, SerialNumber FROM Asset WHERE SerialNumber LIKE 'LPG-%-RTU%']) {
    assetBySerial.put(a.SerialNumber, a);
}
List<Asset> units = new List<Asset>();
for (String code : UNIT_SPECS.keySet()) {
    Integer n = 0;
    for (String spec : UNIT_SPECS.get(code)) {
        n++;
        List<String> p = spec.split('\\|');
        String tag = 'RTU-' + (n < 10 ? '0' : '') + n;
        String serial = code + '-' + tag.remove('-');
        Asset a = assetBySerial.containsKey(serial) ? assetBySerial.get(serial) : new Asset(SerialNumber = serial);
        a.Name = tag + ' ' + p[4];
        a.AccountId = accountByCode.get(code).Id;
        a.LocationId = locationByName.get(SITES.get(code)[0]).Id;
        a.RLM_HVAC_Unit_Tag__c = tag;
        a.RLM_HVAC_Tonnage__c = Decimal.valueOf(p[0]);
        a.RLM_HVAC_Install_Year__c = Integer.valueOf(p[1]);
        a.RLM_HVAC_Refrigerant_Type__c = p[2];
        a.RLM_HVAC_Refrigerant_Charge__c = Decimal.valueOf(p[3]);
        a.InstallDate = Date.newInstance(Integer.valueOf(p[1]), 5, 1);
        a.Status = 'Installed';
        units.add(a);
    }
}
upsert units;

System.debug('seedHvacCommercialNewSite complete: accounts=' + accounts.size() + ', new contacts=' + contacts.size()
    + ', new locations=' + newLocations.size() + ', units=' + units.size());
