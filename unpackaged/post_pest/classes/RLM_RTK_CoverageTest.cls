@IsTest
private class RLM_RTK_CoverageTest {
    private static Map<String, Id> workTypes() {
        List<WorkType> types = new List<WorkType>();
        for (String name : new List<String>{ 'Initial Pest Treatment', 'Monthly Pest Visit', 'Termite Monitoring', 'Pest Re-service' }) {
            types.add(new WorkType(Name = name, EstimatedDuration = 1, DurationType = 'Hours', ShouldAutoCreateSvcAppt = false));
        }
        insert types;
        Map<String, Id> byName = new Map<String, Id>();
        for (WorkType wt : types) {
            byName.put(wt.Name, wt.Id);
        }
        return byName;
    }

    private static Account customerWithPlans() {
        Account account = new Account(Name = 'Coverage Test Home', ShippingPostalCode = '60108');
        insert account;
        // Product SKUs are unique org-wide, including the real catalog, so the test plans use their own.
        Product2 home = new Product2(Name = 'Home Protection Plan', StockKeepingUnit = 'RTK-HOME-PROT-COVTEST', IsActive = true);
        Product2 termite = new Product2(Name = 'Termite Plan', StockKeepingUnit = 'RTK-TERMITE-COVTEST', IsActive = true);
        insert new List<Product2>{ home, termite };
        insert new List<Asset>{
            new Asset(Name = 'Home Protection Plan', AccountId = account.Id, Product2Id = home.Id),
            new Asset(Name = 'Termite Plan', AccountId = account.Id, Product2Id = termite.Id)
        };
        RLM_RTK_Coverage.CADENCES.put(home.StockKeepingUnit, RLM_RTK_Coverage.CADENCES.get('RTK-HOME-PROT'));
        RLM_RTK_Coverage.CADENCES.put(termite.StockKeepingUnit, RLM_RTK_Coverage.CADENCES.get('RTK-TERMITE'));
        return account;
    }

    @IsTest
    static void activateCreatesGuaranteesAndOnePlanOnce() {
        workTypes();
        Account account = customerWithPlans();

        Set<Id> changed = RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });

        Assert.areEqual(1, changed.size());
        List<Entitlement> guarantees = [SELECT Name, RLM_RTK_Covered_Pests__c FROM Entitlement WHERE AccountId = :account.Id ORDER BY Name];
        Assert.areEqual(2, guarantees.size());
        Assert.areEqual('Home Protection Plan guarantee', guarantees[0].Name);
        Assert.isTrue(guarantees[0].RLM_RTK_Covered_Pests__c.contains('Rodents'));
        Assert.areEqual('Termites', guarantees[1].RLM_RTK_Covered_Pests__c);
        MaintenancePlan plan = [
            SELECT WorkType.Name, WorkOrderGenerationMethod, NextSuggestedMaintenanceDate
            FROM MaintenancePlan WHERE AccountId = :account.Id
        ];
        Assert.areEqual('Monthly Pest Visit', plan.WorkType.Name);
        Assert.areEqual('WorkOrderLineItemPerAsset', plan.WorkOrderGenerationMethod);
        Assert.areEqual(Date.today().addMonths(1), plan.NextSuggestedMaintenanceDate);
        Assert.areEqual(2, [SELECT COUNT() FROM MaintenanceAsset WHERE MaintenancePlanId = :plan.Id]);
        Map<String, String> recurrenceByTitle = new Map<String, String>();
        for (MaintenanceWorkRule rule : [SELECT Title, RecurrencePattern FROM MaintenanceWorkRule WHERE ParentMaintenanceRecord.MaintenancePlanId = :plan.Id]) {
            recurrenceByTitle.put(rule.Title, rule.RecurrencePattern);
        }
        Assert.areEqual('FREQ=MONTHLY;INTERVAL=1', recurrenceByTitle.get('Monthly Pest Visit'));
        Assert.areEqual('FREQ=YEARLY;INTERVAL=1', recurrenceByTitle.get('Termite Monitoring'));

        WorkOrder visit = new WorkOrder(AccountId = account.Id, MaintenancePlanId = plan.Id,
            SuggestedMaintenanceDate = plan.NextSuggestedMaintenanceDate);
        insert visit;
        Assert.areEqual('Monthly Pest Visit', [SELECT WorkType.Name FROM WorkOrder WHERE Id = :visit.Id].WorkType.Name);
    }

    @IsTest
    static void mosquitoVisitsWaitForTheSeason() {
        RLM_RTK_Coverage.Cadence mosquito = RLM_RTK_Coverage.CADENCES.get('RTK-MOSQUITO');
        Assert.areEqual(Date.newInstance(2027, 4, 28), mosquito.firstVisit(Date.newInstance(2026, 10, 28)));
        Assert.areEqual(Date.newInstance(2026, 7, 15), mosquito.firstVisit(Date.newInstance(2026, 6, 15)));
    }

    @IsTest
    static void reserviceIsCoveredOnlyForGuaranteedPests() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });

        WorkOrder ants = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('Pest Re-service'), RLM_RTK_Reported_Pest__c = 'Ants');
        WorkOrder bedBugs = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('Pest Re-service'), RLM_RTK_Reported_Pest__c = 'Bed Bugs');
        WorkOrder unknown = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('Pest Re-service'));
        insert new List<WorkOrder>{ ants, bedBugs, unknown };

        ants = [SELECT RLM_Service_Coverage__c, EntitlementId, Entitlement.Name, AssetId FROM WorkOrder WHERE Id = :ants.Id];
        Assert.areEqual('Covered', ants.RLM_Service_Coverage__c);
        Assert.areEqual('Home Protection Plan guarantee', ants.Entitlement.Name);
        Assert.isNotNull(ants.AssetId);
        bedBugs = [SELECT RLM_Service_Coverage__c, EntitlementId FROM WorkOrder WHERE Id = :bedBugs.Id];
        Assert.areEqual('Not Covered', bedBugs.RLM_Service_Coverage__c);
        Assert.isNull(bedBugs.EntitlementId);
        Assert.isNull([SELECT RLM_Service_Coverage__c FROM WorkOrder WHERE Id = :unknown.Id].RLM_Service_Coverage__c);

        unknown.RLM_RTK_Reported_Pest__c = 'Termites';
        update unknown;
        Assert.areEqual('Covered', [SELECT RLM_Service_Coverage__c FROM WorkOrder WHERE Id = :unknown.Id].RLM_Service_Coverage__c);
    }

    @IsTest
    static void visitsCopyTheCustomersTerritoryAddressAndInspection() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        OperatingHours hours = new OperatingHours(Name = 'Coverage Test Hours');
        insert hours;
        ServiceTerritory territory = new ServiceTerritory(Name = 'Coverage Test Territory', OperatingHoursId = hours.Id, IsActive = true);
        insert territory;
        Contact contact = new Contact(AccountId = account.Id, LastName = 'Customer');
        insert contact;
        RLM_RTK_Inspection__c inspection = new RLM_RTK_Inspection__c(Account__c = account.Id, Status__c = 'Accepted');
        insert inspection;
        insert new WorkOrder(AccountId = account.Id, ServiceTerritoryId = territory.Id, ContactId = contact.Id,
            Street = '58 Maple Ridge Dr', City = 'Bloomingdale', State = 'IL', PostalCode = '60108');

        WorkOrder visit = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('Pest Re-service'), RLM_RTK_Reported_Pest__c = 'Ants');
        insert visit;

        visit = [SELECT ServiceTerritoryId, ContactId, Street, PostalCode, RLM_RTK_Inspection__c FROM WorkOrder WHERE Id = :visit.Id];
        Assert.areEqual(territory.Id, visit.ServiceTerritoryId);
        Assert.areEqual(contact.Id, visit.ContactId);
        Assert.areEqual('58 Maple Ridge Dr', visit.Street);
        Assert.areEqual(inspection.Id, visit.RLM_RTK_Inspection__c);
    }

    @IsTest
    static void completingTheInitialTreatmentStartsCoverage() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        WorkOrder initial = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('Initial Pest Treatment'));
        insert initial;

        Test.startTest();
        initial.Status = 'Completed';
        update initial;
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Entitlement WHERE AccountId = :account.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM MaintenancePlan WHERE AccountId = :account.Id]);
    }
}
