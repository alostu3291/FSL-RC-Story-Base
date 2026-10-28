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
    static void aCoveredReserviceIsDueIn48HoursAndMetWhenTheTechnicianArrives() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });
        SlaProcess process = [SELECT Id FROM SlaProcess WHERE Name = :RLM_RTK_Coverage.RESPONSE_PROCESS AND IsActive = true];
        for (Entitlement e : [SELECT SlaProcessId FROM Entitlement WHERE AccountId = :account.Id]) {
            Assert.areEqual(process.Id, e.SlaProcessId);
        }

        WorkOrder ants = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('Pest Re-service'), RLM_RTK_Reported_Pest__c = 'Ants');
        WorkOrder bedBugs = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('Pest Re-service'), RLM_RTK_Reported_Pest__c = 'Bed Bugs');
        insert new List<WorkOrder>{ ants, bedBugs };
        EntityMilestone response = [
            SELECT MilestoneType.Name, StartDate, TargetDate, IsCompleted FROM EntityMilestone WHERE ParentEntityId = :ants.Id
        ];
        Assert.areEqual(RLM_RTK_Coverage.RESPONSE_MILESTONE, response.MilestoneType.Name);
        Assert.isFalse(response.IsCompleted);
        Assert.isTrue(response.TargetDate > response.StartDate.addHours(47).addMinutes(58));
        Assert.areEqual(0, [SELECT COUNT() FROM EntityMilestone WHERE ParentEntityId = :bedBugs.Id]);

        ServiceAppointment sa = new ServiceAppointment(ParentRecordId = ants.Id, Status = 'Scheduled',
            EarliestStartTime = Datetime.now(), DueDate = Datetime.now().addDays(2));
        insert sa;
        sa.Status = 'Dispatched';
        update sa;
        Assert.isFalse([SELECT IsCompleted FROM EntityMilestone WHERE Id = :response.Id].IsCompleted);
        sa.Status = 'In Progress';
        sa.ActualStartTime = Datetime.now().addMinutes(-5);
        update sa;
        response = [SELECT IsCompleted, IsViolated, CompletionDate FROM EntityMilestone WHERE Id = :response.Id];
        Assert.isTrue(response.IsCompleted);
        Assert.isFalse(response.IsViolated);
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

    private static Asset addPlan(Id accountId, String name, String sku) {
        Product2 product = new Product2(Name = name, StockKeepingUnit = sku + '-COVTEST', IsActive = true);
        insert product;
        RLM_RTK_Coverage.CADENCES.put(product.StockKeepingUnit, RLM_RTK_Coverage.CADENCES.get(sku));
        Asset plan = new Asset(Name = name, AccountId = accountId, Product2Id = product.Id);
        insert plan;
        return plan;
    }

    private static void activeFor(Id assetId, List<RLM_RTK_Coverage.Stretch> stretches) {
        RLM_RTK_Coverage.stretchesByAsset.put(assetId, stretches);
    }

    private static RLM_RTK_Coverage.Stretch stretch(Date startDate, Date endDate) {
        return new RLM_RTK_Coverage.Stretch(startDate, endDate);
    }

    /** A generated visit: a work order with one line for the plan asset. */
    private static WorkOrderLineItem visit(Id accountId, Id planId, Id assetId, Date day) {
        WorkOrder wo = new WorkOrder(AccountId = accountId, MaintenancePlanId = planId, SuggestedMaintenanceDate = day);
        insert wo;
        WorkOrderLineItem line = new WorkOrderLineItem(WorkOrderId = wo.Id, AssetId = assetId,
            MaintenancePlanId = planId, SuggestedMaintenanceDate = day);
        insert line;
        return line;
    }

    private static Asset homePlan(Id accountId) {
        return [SELECT Id FROM Asset WHERE AccountId = :accountId AND Name = 'Home Protection Plan'];
    }

    @IsTest
    static void statePeriodsBecomeActiveStretches() {
        List<AssetStatePeriod> periods = (List<AssetStatePeriod>) JSON.deserialize('['
            + '{"StartDate":"2026-01-01T00:00:00.000+0000","EndDate":"2026-03-31T23:59:59.000+0000","Quantity":1},'
            + '{"StartDate":"2026-04-01T00:00:00.000+0000","EndDate":"2026-10-31T23:59:59.000+0000","Quantity":1},'
            + '{"StartDate":"2026-11-01T00:00:00.000+0000","EndDate":"2027-03-31T23:59:59.000+0000","Quantity":0},'
            + '{"StartDate":"2027-04-01T00:00:00.000+0000","Quantity":1}]', List<AssetStatePeriod>.class);

        List<RLM_RTK_Coverage.Stretch> stretches = RLM_RTK_Coverage.stretchesFrom(periods);

        Assert.areEqual(2, stretches.size(), 'Back-to-back periods join; the zero-quantity pause splits them');
        Assert.areEqual(Date.newInstance(2026, 1, 1), stretches[0].startDate);
        Assert.areEqual(Date.newInstance(2026, 10, 31), stretches[0].endDate);
        Assert.areEqual(Date.newInstance(2027, 4, 1), stretches[1].startDate);
        Assert.isNull(stretches[1].endDate, 'The resumed plan is open-ended');
    }

    @IsTest
    static void anUpgradeMovesUpcomingVisitsToTheNewPlan() {
        workTypes();
        Account account = new Account(Name = 'Upgrade Home');
        insert account;
        Date today = Date.today();
        Asset home = addPlan(account.Id, 'Home Protection Plan', 'RTK-HOME-PROT');
        activeFor(home.Id, new List<RLM_RTK_Coverage.Stretch>{ stretch(today.addDays(-30), null) });
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });
        Id planId = [SELECT Id FROM MaintenancePlan WHERE AccountId = :account.Id].Id;
        Date nextVisit = today.addMonths(1);
        WorkOrderLineItem line = visit(account.Id, planId, home.Id, nextVisit);

        Asset plus = addPlan(account.Id, 'Home Protection Plus', 'RTK-HOME-PROT-PLUS');
        activeFor(home.Id, new List<RLM_RTK_Coverage.Stretch>{ stretch(today.addDays(-30), today) });
        activeFor(plus.Id, new List<RLM_RTK_Coverage.Stretch>{ stretch(today.addDays(1), null) });
        RLM_RTK_Coverage.sync(new Set<Id>{ account.Id });

        Assert.areEqual(today, [SELECT EndDate FROM Entitlement WHERE AssetId = :home.Id].EndDate, 'The old guarantee ends with its plan');
        Entitlement plusGuarantee = [SELECT StartDate, EndDate, RLM_RTK_Covered_Pests__c FROM Entitlement WHERE AssetId = :plus.Id];
        Assert.areEqual(today.addDays(1), plusGuarantee.StartDate);
        Assert.isNull(plusGuarantee.EndDate);
        Assert.isTrue(plusGuarantee.RLM_RTK_Covered_Pests__c.contains('Wasps / Bees'));
        Assert.areEqual(plus.Id, [SELECT AssetId FROM WorkOrderLineItem WHERE Id = :line.Id].AssetId, 'The upcoming visit keeps its day as a Plus visit');
        Assert.areEqual(0, [SELECT COUNT() FROM MaintenanceAsset WHERE AssetId = :home.Id], 'The old plan stops generating visits');
        Assert.areEqual(nextVisit.addMonths(1), [
            SELECT NextSuggestedMaintenanceDate FROM MaintenanceWorkRule WHERE ParentMaintenanceRecord.AssetId = :plus.Id
        ].NextSuggestedMaintenanceDate, 'Plus visits continue after the carried visit');
    }

    @IsTest
    static void aPauseSplitsTheGuaranteeAndSkipsVisitsInTheGap() {
        workTypes();
        Account account = new Account(Name = 'Pause Home');
        insert account;
        Date today = Date.today();
        Asset home = addPlan(account.Id, 'Home Protection Plan', 'RTK-HOME-PROT');
        activeFor(home.Id, new List<RLM_RTK_Coverage.Stretch>{ stretch(today.addDays(-30), null) });
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });
        Id planId = [SELECT Id FROM MaintenancePlan WHERE AccountId = :account.Id].Id;
        Date first = today.addMonths(1);
        Date second = first.addMonths(1);
        Date resume = second.addMonths(1);
        WorkOrderLineItem firstLine = visit(account.Id, planId, home.Id, first);
        WorkOrderLineItem secondLine = visit(account.Id, planId, home.Id, second);

        activeFor(home.Id, new List<RLM_RTK_Coverage.Stretch>{
            stretch(today.addDays(-30), first.addDays(-1)), stretch(resume, null)
        });
        RLM_RTK_Coverage.sync(new Set<Id>{ account.Id });

        List<Entitlement> guarantees = [SELECT Name, StartDate, EndDate FROM Entitlement WHERE AssetId = :home.Id ORDER BY StartDate];
        Assert.areEqual(2, guarantees.size(), 'One guarantee before the pause and one after');
        Assert.areEqual(first.addDays(-1), guarantees[0].EndDate);
        Assert.areEqual(resume, guarantees[1].StartDate);
        Assert.isNull(guarantees[1].EndDate);
        Assert.isTrue(guarantees[1].Name.endsWith('from ' + resume.format()));
        Assert.areEqual(0, [SELECT COUNT() FROM WorkOrder WHERE Id IN (:firstLine.WorkOrderId, :secondLine.WorkOrderId)],
            'Visits during the pause are removed');
        Assert.areEqual(resume, [
            SELECT NextSuggestedMaintenanceDate FROM MaintenanceWorkRule WHERE ParentMaintenanceRecord.AssetId = :home.Id
        ].NextSuggestedMaintenanceDate, 'Visits resume with the plan');
    }

    @IsTest
    static void aCancellationEndsTheGuaranteeAndStopsVisits() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        Date today = Date.today();
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });
        Id planId = [SELECT Id FROM MaintenancePlan WHERE AccountId = :account.Id].Id;
        Asset home = homePlan(account.Id);
        WorkOrderLineItem line = visit(account.Id, planId, home.Id, today.addMonths(1));

        activeFor(home.Id, new List<RLM_RTK_Coverage.Stretch>{ stretch(today, today.addDays(5)) });
        RLM_RTK_Coverage.sync(new Set<Id>{ account.Id });

        Assert.areEqual(today.addDays(5), [SELECT EndDate FROM Entitlement WHERE AssetId = :home.Id].EndDate);
        Assert.areEqual(0, [SELECT COUNT() FROM WorkOrder WHERE Id = :line.WorkOrderId], 'Visits after the cancellation are removed');
        Assert.areEqual(0, [SELECT COUNT() FROM MaintenanceAsset WHERE AssetId = :home.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM MaintenanceAsset WHERE MaintenancePlanId = :planId], 'The termite plan keeps its visits');
        Assert.areEqual(types.get('Termite Monitoring'), [SELECT WorkTypeId FROM MaintenancePlan WHERE Id = :planId].WorkTypeId,
            'The remaining plan leads the visits');
    }

    @IsTest
    static void syncRemovesDuplicateGuarantees() {
        workTypes();
        Account account = customerWithPlans();
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });
        Entitlement original = [SELECT Name, AccountId, AssetId, StartDate, RLM_RTK_Covered_Pests__c FROM Entitlement
            WHERE AccountId = :account.Id AND Name = 'Home Protection Plan guarantee'];
        insert original.clone(false, true);

        RLM_RTK_Coverage.sync(new Set<Id>{ account.Id });

        Assert.areEqual(1, [SELECT COUNT() FROM Entitlement WHERE AssetId = :original.AssetId]);
    }

    @IsTest
    static void planAssetChangesSyncTheCustomer() {
        workTypes();
        Account account = customerWithPlans();
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });
        Asset home = homePlan(account.Id);
        activeFor(home.Id, new List<RLM_RTK_Coverage.Stretch>{ stretch(Date.today(), Date.today()) });

        Test.startTest();
        update home;
        Test.stopTest();

        Assert.areEqual(Date.today(), [SELECT EndDate FROM Entitlement WHERE AssetId = :home.Id].EndDate);
    }

    @IsTest
    static void nightlySyncCoversEveryCustomer() {
        workTypes();
        Account account = customerWithPlans();
        RLM_RTK_Coverage.activate(new Set<Id>{ account.Id });
        Asset home = homePlan(account.Id);
        activeFor(home.Id, new List<RLM_RTK_Coverage.Stretch>{ stretch(Date.today(), Date.today().addDays(10)) });

        Test.startTest();
        RLM_RTK_Coverage.syncAll();
        Test.stopTest();

        Assert.areEqual(Date.today().addDays(10), [SELECT EndDate FROM Entitlement WHERE AssetId = :home.Id].EndDate);
    }
}
