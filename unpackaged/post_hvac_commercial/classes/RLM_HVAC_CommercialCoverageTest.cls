@IsTest
private class RLM_HVAC_CommercialCoverageTest {
    // Product SKUs are unique org-wide, including the real catalog, so the test coverage uses its own.
    private static final String RESPONSE_SKU = 'HVAC-COM-RESP-4H-COVTEST';

    private class Fixture {
        Account parent;
        Account site;
        Id locationId;
        Asset response;
        List<Asset> units = new List<Asset>();
        Map<String, Id> workTypes = new Map<String, Id>();
    }

    private static Fixture fixture() {
        Fixture f = new Fixture();
        List<WorkType> types = new List<WorkType>{
            new WorkType(Name = RLM_HVAC_CommercialCoverage.MAINTENANCE_WORK_TYPE, EstimatedDuration = 4,
                DurationType = 'Hours', ShouldAutoCreateSvcAppt = false),
            new WorkType(Name = RLM_HVAC_Coverage.SERVICE_CALL, EstimatedDuration = 2, DurationType = 'Hours',
                ShouldAutoCreateSvcAppt = false)
        };
        insert types;
        for (WorkType wt : types) {
            f.workTypes.put(wt.Name, wt.Id);
        }
        f.parent = new Account(Name = 'Coverage Test Group', RLM_HVAC_Site_Type__c = 'Headquarters');
        insert f.parent;
        insert new Contact(AccountId = f.parent.Id, LastName = 'Director', Title = 'Director of Facilities');
        f.site = new Account(Name = 'Coverage Test Bistro', ParentId = f.parent.Id, RLM_HVAC_Site_Type__c = 'Restaurant',
            BillingStreet = '10 Test St', BillingCity = 'Naperville', BillingState = 'IL', BillingPostalCode = '60540',
            BillingCountry = 'United States');
        insert f.site;
        Schema.Location l = new Schema.Location(Name = 'Coverage Test Bistro', LocationType = 'Site',
            IsInventoryLocation = false, IsMobile = false);
        insert l;
        f.locationId = l.Id;
        insert new AssociatedLocation(ParentRecordId = f.site.Id, LocationId = l.Id, Type = 'Ship To');

        Product2 response = new Product2(Name = '4-Hour Response', StockKeepingUnit = RESPONSE_SKU, IsActive = true);
        insert response;
        f.response = new Asset(Name = '4-Hour Response', AccountId = f.parent.Id, Product2Id = response.Id,
            RLM_HVAC_Site__c = f.site.Id);
        f.units.add(new Asset(Name = 'RTU-01', AccountId = f.site.Id, RLM_HVAC_Unit_Tag__c = 'RTU-01', RLM_HVAC_Tonnage__c = 5));
        f.units.add(new Asset(Name = 'RTU-02', AccountId = f.site.Id, RLM_HVAC_Unit_Tag__c = 'RTU-02', RLM_HVAC_Tonnage__c = 10));
        List<Asset> all = new List<Asset>{ f.response };
        all.addAll(f.units);
        insert all;
        RLM_HVAC_Coverage.SITE_RESPONSE.put(RESPONSE_SKU, RLM_HVAC_Coverage.SITE_RESPONSE.get('HVAC-COM-RESP-4H'));
        return f;
    }

    @IsTest
    static void eachSiteGetsAResponseEntitlementAndAQuarterlyPlanOnce() {
        Fixture f = fixture();

        Set<Id> changed = RLM_HVAC_CommercialCoverage.activate(new Set<Id>{ f.site.Id });
        Set<Id> again = RLM_HVAC_CommercialCoverage.activate(new Set<Id>{ f.site.Id });

        Assert.areEqual(1, changed.size());
        Assert.isTrue(again.isEmpty(), 'a second run changes nothing');
        Entitlement e = [SELECT Name, AccountId, AssetId, StartDate, RLM_HVAC_Covered_Systems__c FROM Entitlement];
        Assert.areEqual(f.site.Id, e.AccountId, 'the site holds the entitlement so its calls find it');
        Assert.areEqual(f.response.Id, e.AssetId);
        Assert.areEqual('Coverage Test Bistro - 4 hours, 24/7 response', e.Name);
        Assert.areEqual('Cooling;Heating', e.RLM_HVAC_Covered_Systems__c);
        MaintenancePlan plan = [
            SELECT AccountId, LocationId, WorkType.Name, WorkOrderGenerationMethod, NextSuggestedMaintenanceDate
            FROM MaintenancePlan
        ];
        Assert.areEqual(f.site.Id, plan.AccountId);
        Assert.areEqual(f.locationId, plan.LocationId);
        Assert.areEqual(RLM_HVAC_CommercialCoverage.MAINTENANCE_WORK_TYPE, plan.WorkType.Name);
        Assert.areEqual('WorkOrderLineItemPerAsset', plan.WorkOrderGenerationMethod);
        Assert.areEqual(Date.today(), plan.NextSuggestedMaintenanceDate);
        List<MaintenanceWorkRule> rules = [SELECT RecurrencePattern FROM MaintenanceWorkRule];
        Assert.areEqual(2, rules.size(), 'one quarterly rule per rooftop unit');
        Assert.areEqual(RLM_HVAC_CommercialCoverage.QUARTERLY_RULE, rules[0].RecurrencePattern);
    }

    @IsTest
    static void aSiteServiceCallIsCoveredAtItsResponseTier() {
        Fixture f = fixture();
        RLM_HVAC_CommercialCoverage.activate(new Set<Id>{ f.site.Id });

        WorkOrder call = new WorkOrder(AccountId = f.site.Id, WorkTypeId = f.workTypes.get(RLM_HVAC_Coverage.SERVICE_CALL),
            RLM_HVAC_Reported_Issue__c = 'No Cool');
        insert call;

        call = [SELECT RLM_Service_Coverage__c, Priority, AssetId FROM WorkOrder WHERE Id = :call.Id];
        Assert.areEqual(RLM_HVAC_Coverage.COVERED, call.RLM_Service_Coverage__c);
        Assert.areEqual('Critical', call.Priority, 'restaurants get the 4-hour response');
    }

    @IsTest
    static void generatedVisitsTakeTheSiteAddressLocationAndContact() {
        Fixture f = fixture();
        RLM_HVAC_CommercialCoverage.activate(new Set<Id>{ f.site.Id });
        MaintenancePlan plan = [SELECT Id FROM MaintenancePlan];

        WorkOrder visit = new WorkOrder(AccountId = f.site.Id, MaintenancePlanId = plan.Id,
            SuggestedMaintenanceDate = Date.today());
        insert visit;

        visit = [SELECT LocationId, Street, City, ContactId, Contact.Title FROM WorkOrder WHERE Id = :visit.Id];
        Assert.areEqual(f.locationId, visit.LocationId);
        Assert.areEqual('10 Test St', visit.Street);
        Assert.areEqual('Director of Facilities', visit.Contact.Title);
    }

    @IsTest
    static void assetsWithoutAnOrderSourceWait() {
        Fixture f = fixture();
        Asset unstamped = new Asset(Name = '4-Hour Response', AccountId = f.parent.Id, Product2Id = f.response.Product2Id);
        insert unstamped;

        Set<Id> waiting = new Set<Id>();
        Set<Id> sites = RLM_HVAC_CommercialCoverage.stampSites(new Set<Id>{ unstamped.Id }, waiting);

        Assert.isTrue(sites.isEmpty());
        Assert.isTrue(waiting.contains(unstamped.Id), 'retried once assetization adds the action source');
    }

    @IsTest
    static void bookingNeedsApprovalAndAPurchaseOrder() {
        Fixture f = fixture();
        Opportunity o = new Opportunity(Name = 'Contract', StageName = 'Prospecting', CloseDate = Date.today(), AccountId = f.parent.Id);
        insert o;
        Quote q = new Quote(Name = 'Contract Quote', OpportunityId = o.Id, Pricebook2Id = Test.getStandardPricebookId(),
            RLM_Line_of_Business__c = RLM_HVAC_CommercialPricing.LOB);
        insert q;

        RLM_HVAC_ContractOrder.Status s = RLM_HVAC_ContractOrder.status(q.Id);
        Assert.areEqual('None', s.orderStatus);
        Assert.isFalse(s.awaitingApproval);
        try {
            RLM_HVAC_ContractOrder.placeOrder(q.Id, ' ');
            Assert.fail('a contract needs the customer PO');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('PO number'), e.getMessage());
        }

        Quote residential = new Quote(Name = 'Home Quote', OpportunityId = o.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert residential;
        try {
            RLM_HVAC_ContractOrder.status(residential.Id);
            Assert.fail('only commercial contract quotes are booked here');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Commercial HVAC'), e.getMessage());
        }
    }
}
