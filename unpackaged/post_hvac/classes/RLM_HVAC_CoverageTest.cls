@IsTest
private class RLM_HVAC_CoverageTest {
    private static Map<String, Id> workTypes() {
        List<WorkType> types = new List<WorkType>();
        for (String name : new List<String>{ 'Initial Tune-up', 'Spring AC Tune-up', 'Fall Furnace Tune-up',
                'Water Heater Flush', 'Indoor Air Quality Visit', 'No-Cool / No-Heat Call' }) {
            types.add(new WorkType(Name = name, EstimatedDuration = 1, DurationType = 'Hours', ShouldAutoCreateSvcAppt = false));
        }
        insert types;
        Map<String, Id> byName = new Map<String, Id>();
        for (WorkType wt : types) {
            byName.put(wt.Name, wt.Id);
        }
        return byName;
    }

    private static RLM_HVAC_Coverage.Cadence tuneUps() {
        return RLM_HVAC_Coverage.CADENCES.get('HVAC-PLUS');
    }

    private static Account customerWithPlans() {
        Account account = new Account(Name = 'Coverage Test Home', ShippingPostalCode = '60540');
        insert account;
        // Product SKUs are unique org-wide, including the real catalog, so the test agreements use their own.
        Product2 plus = new Product2(Name = 'Comfort Plus', StockKeepingUnit = 'HVAC-PLUS-COVTEST', IsActive = true);
        Product2 waterHeater = new Product2(Name = 'Water Heater Care', StockKeepingUnit = 'HVAC-WATER-HEATER-COVTEST', IsActive = true);
        insert new List<Product2>{ plus, waterHeater };
        insert new List<Asset>{
            new Asset(Name = 'Comfort Plus', AccountId = account.Id, Product2Id = plus.Id),
            new Asset(Name = 'Water Heater Care', AccountId = account.Id, Product2Id = waterHeater.Id)
        };
        RLM_HVAC_Coverage.CADENCES.put(plus.StockKeepingUnit, RLM_HVAC_Coverage.CADENCES.get('HVAC-PLUS'));
        RLM_HVAC_Coverage.CADENCES.put(waterHeater.StockKeepingUnit, RLM_HVAC_Coverage.CADENCES.get('HVAC-WATER-HEATER'));
        return account;
    }

    @IsTest
    static void activateCreatesEntitlementsAndOnePlanOnce() {
        workTypes();
        Account account = customerWithPlans();

        Set<Id> changed = RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });

        Assert.areEqual(1, changed.size());
        List<Entitlement> coverage = [SELECT Name, RLM_HVAC_Covered_Systems__c FROM Entitlement WHERE AccountId = :account.Id ORDER BY Name];
        Assert.areEqual(2, coverage.size());
        Assert.areEqual('Comfort Plus coverage', coverage[0].Name);
        Assert.areEqual('Cooling;Heating', coverage[0].RLM_HVAC_Covered_Systems__c);
        Assert.areEqual('Water Heater', coverage[1].RLM_HVAC_Covered_Systems__c);
        MaintenancePlan plan = [
            SELECT WorkType.Name, WorkOrderGenerationMethod, NextSuggestedMaintenanceDate
            FROM MaintenancePlan WHERE AccountId = :account.Id
        ];
        Assert.areEqual('Spring AC Tune-up', plan.WorkType.Name);
        Assert.areEqual('WorkOrderLineItemPerAsset', plan.WorkOrderGenerationMethod);
        Date firstTuneUp = tuneUps().firstVisit(Date.today());
        Assert.areEqual(firstTuneUp, plan.NextSuggestedMaintenanceDate);
        Assert.isTrue(firstTuneUp.month() == 4 || firstTuneUp.month() == 10, 'Tune-ups fall in April or October');
        Assert.areEqual(2, [SELECT COUNT() FROM MaintenanceAsset WHERE MaintenancePlanId = :plan.Id]);
        Map<String, String> recurrenceByTitle = new Map<String, String>();
        for (MaintenanceWorkRule rule : [SELECT Title, RecurrencePattern FROM MaintenanceWorkRule WHERE ParentMaintenanceRecord.MaintenancePlanId = :plan.Id]) {
            recurrenceByTitle.put(rule.Title, rule.RecurrencePattern);
        }
        Assert.areEqual('FREQ=MONTHLY;BYMONTH=4,10', recurrenceByTitle.get('Spring AC Tune-up'));
        Assert.areEqual('FREQ=YEARLY;INTERVAL=1', recurrenceByTitle.get('Water Heater Flush'));

        WorkOrder visit = new WorkOrder(AccountId = account.Id, MaintenancePlanId = plan.Id,
            SuggestedMaintenanceDate = plan.NextSuggestedMaintenanceDate);
        insert visit;
        Assert.areEqual(tuneUps().workTypeOn(firstTuneUp), [SELECT WorkType.Name FROM WorkOrder WHERE Id = :visit.Id].WorkType.Name);
    }

    @IsTest
    static void tuneUpsAreSpringAndFall() {
        RLM_HVAC_Coverage.Cadence tuneUp = tuneUps();
        Assert.areEqual(Date.newInstance(2027, 4, 28), tuneUp.firstVisit(Date.newInstance(2026, 10, 28)));
        Assert.areEqual(Date.newInstance(2026, 10, 15), tuneUp.firstVisit(Date.newInstance(2026, 6, 15)));
        Assert.areEqual('Spring AC Tune-up', tuneUp.workTypeOn(Date.newInstance(2027, 4, 28)));
        Assert.areEqual('Fall Furnace Tune-up', tuneUp.workTypeOn(Date.newInstance(2026, 10, 15)));
        Assert.areEqual('Water Heater Flush', RLM_HVAC_Coverage.CADENCES.get('HVAC-WATER-HEATER').workTypeOn(Date.newInstance(2026, 10, 15)));
    }

    @IsTest
    static void aFallVisitGeneratedFromTheSpringRuleBecomesAFurnaceTuneUp() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        Id planId = [SELECT Id FROM MaintenancePlan WHERE AccountId = :account.Id].Id;

        WorkOrder fall = new WorkOrder(AccountId = account.Id, MaintenancePlanId = planId,
            WorkTypeId = types.get('Spring AC Tune-up'), SuggestedMaintenanceDate = Date.newInstance(Date.today().year() + 1, 10, 1));
        WorkOrder spring = new WorkOrder(AccountId = account.Id, MaintenancePlanId = planId,
            WorkTypeId = types.get('Spring AC Tune-up'), SuggestedMaintenanceDate = Date.newInstance(Date.today().year() + 1, 4, 1));
        insert new List<WorkOrder>{ fall, spring };

        Assert.areEqual(types.get('Fall Furnace Tune-up'), [SELECT WorkTypeId FROM WorkOrder WHERE Id = :fall.Id].WorkTypeId);
        Assert.areEqual(types.get('Spring AC Tune-up'), [SELECT WorkTypeId FROM WorkOrder WHERE Id = :spring.Id].WorkTypeId);
    }

    @IsTest
    static void aServiceCallIsCoveredOnlyForCoveredSystems() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });

        Id call = types.get('No-Cool / No-Heat Call');
        WorkOrder noCool = new WorkOrder(AccountId = account.Id, WorkTypeId = call, RLM_HVAC_Reported_Issue__c = 'No Cool');
        WorkOrder airQuality = new WorkOrder(AccountId = account.Id, WorkTypeId = call, RLM_HVAC_Reported_Issue__c = 'Air Quality');
        WorkOrder unknown = new WorkOrder(AccountId = account.Id, WorkTypeId = call);
        insert new List<WorkOrder>{ noCool, airQuality, unknown };

        noCool = [SELECT RLM_Service_Coverage__c, EntitlementId, Entitlement.Name, AssetId, Priority FROM WorkOrder WHERE Id = :noCool.Id];
        Assert.areEqual('Covered', noCool.RLM_Service_Coverage__c);
        Assert.areEqual('Comfort Plus coverage', noCool.Entitlement.Name);
        Assert.areEqual('High', noCool.Priority, 'Comfort Plus calls get 8-hour priority');
        Assert.isNotNull(noCool.AssetId);
        airQuality = [SELECT RLM_Service_Coverage__c, EntitlementId FROM WorkOrder WHERE Id = :airQuality.Id];
        Assert.areEqual('Not Covered', airQuality.RLM_Service_Coverage__c, 'Indoor Air Quality is not on the agreement');
        Assert.isNull(airQuality.EntitlementId);
        Assert.isNull([SELECT RLM_Service_Coverage__c FROM WorkOrder WHERE Id = :unknown.Id].RLM_Service_Coverage__c);

        unknown.RLM_HVAC_Reported_Issue__c = 'Water Heater';
        update unknown;
        Assert.areEqual('Covered', [SELECT RLM_Service_Coverage__c FROM WorkOrder WHERE Id = :unknown.Id].RLM_Service_Coverage__c);
        Assert.areEqual(8, RLM_HVAC_Coverage.responseHoursFor('HVAC-PLUS'));
        Assert.areEqual(4, RLM_HVAC_Coverage.responseHoursFor('HVAC-PREMIER'));
    }

    @IsTest
    static void aCoveredCallHasAPriorityResponseMetWhenTheTechnicianArrives() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        SlaProcess process = [SELECT Id FROM SlaProcess WHERE Name = :RLM_HVAC_Coverage.RESPONSE_PROCESS AND IsActive = true];
        for (Entitlement e : [SELECT SlaProcessId FROM Entitlement WHERE AccountId = :account.Id]) {
            Assert.areEqual(process.Id, e.SlaProcessId);
        }

        Id call = types.get('No-Cool / No-Heat Call');
        WorkOrder noHeat = new WorkOrder(AccountId = account.Id, WorkTypeId = call, RLM_HVAC_Reported_Issue__c = 'No Heat');
        WorkOrder airQuality = new WorkOrder(AccountId = account.Id, WorkTypeId = call, RLM_HVAC_Reported_Issue__c = 'Air Quality');
        insert new List<WorkOrder>{ noHeat, airQuality };
        EntityMilestone response = [
            SELECT MilestoneType.Name, StartDate, TargetDate, IsCompleted FROM EntityMilestone WHERE ParentEntityId = :noHeat.Id
        ];
        Assert.areEqual(RLM_HVAC_Coverage.RESPONSE_MILESTONE, response.MilestoneType.Name);
        Assert.isFalse(response.IsCompleted);
        Assert.isTrue(response.TargetDate > response.StartDate.addHours(7).addMinutes(58), 'Comfort Plus: 8 service hours');
        Assert.areEqual(0, [SELECT COUNT() FROM EntityMilestone WHERE ParentEntityId = :airQuality.Id]);
        RLM_HVAC_FieldVisit.ResponseCommitment card = RLM_HVAC_FieldVisit.getVisitTiming(noHeat.Id).response;
        Assert.areEqual(response.TargetDate, card.dueBy);
        Assert.areEqual('No Heat', card.reportedIssue);
        Assert.areEqual('Comfort Plus coverage', card.agreementName);
        Assert.isNull(card.metAt);
        Assert.isNull(RLM_HVAC_FieldVisit.getVisitTiming(airQuality.Id).response, 'Not Covered has no response time to meet');

        ServiceAppointment sa = new ServiceAppointment(ParentRecordId = noHeat.Id, Status = 'Scheduled',
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
        Assert.areEqual(response.CompletionDate, RLM_HVAC_FieldVisit.getVisitTiming(noHeat.Id).response.metAt);
    }

    @IsTest
    static void visitsCopyTheCustomersTerritoryAddressAndSystemCheck() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        OperatingHours hours = new OperatingHours(Name = 'Coverage Test Hours');
        insert hours;
        ServiceTerritory territory = new ServiceTerritory(Name = 'Coverage Test Territory', OperatingHoursId = hours.Id, IsActive = true);
        insert territory;
        Contact contact = new Contact(AccountId = account.Id, LastName = 'Customer');
        insert contact;
        RLM_HVAC_Assessment__c assessment = new RLM_HVAC_Assessment__c(Account__c = account.Id, Status__c = 'Accepted');
        insert assessment;
        insert new WorkOrder(AccountId = account.Id, ServiceTerritoryId = territory.Id, ContactId = contact.Id,
            Street = '1240 Aurora Ave', City = 'Naperville', State = 'IL', PostalCode = '60540');

        WorkOrder visit = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('No-Cool / No-Heat Call'), RLM_HVAC_Reported_Issue__c = 'No Cool');
        insert visit;

        visit = [SELECT ServiceTerritoryId, ContactId, Street, PostalCode, RLM_HVAC_Assessment__c FROM WorkOrder WHERE Id = :visit.Id];
        Assert.areEqual(territory.Id, visit.ServiceTerritoryId);
        Assert.areEqual(contact.Id, visit.ContactId);
        Assert.areEqual('1240 Aurora Ave', visit.Street);
        Assert.areEqual(assessment.Id, visit.RLM_HVAC_Assessment__c);
    }

    @IsTest
    static void completingTheInitialTuneUpStartsCoverage() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        WorkOrder initial = new WorkOrder(AccountId = account.Id, WorkTypeId = types.get('Initial Tune-up'));
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
        RLM_HVAC_Coverage.CADENCES.put(product.StockKeepingUnit, RLM_HVAC_Coverage.CADENCES.get(sku));
        Asset plan = new Asset(Name = name, AccountId = accountId, Product2Id = product.Id);
        insert plan;
        return plan;
    }

    private static void activeFor(Id assetId, List<RLM_HVAC_Coverage.Stretch> stretches) {
        RLM_HVAC_Coverage.stretchesByAsset.put(assetId, stretches);
    }

    private static RLM_HVAC_Coverage.Stretch stretch(Date startDate, Date endDate) {
        return new RLM_HVAC_Coverage.Stretch(startDate, endDate);
    }

    /** A generated visit: a work order with one line for the agreement asset. */
    private static WorkOrderLineItem visit(Id accountId, Id planId, Id assetId, Date day) {
        WorkOrder wo = new WorkOrder(AccountId = accountId, MaintenancePlanId = planId, SuggestedMaintenanceDate = day);
        insert wo;
        WorkOrderLineItem line = new WorkOrderLineItem(WorkOrderId = wo.Id, AssetId = assetId,
            MaintenancePlanId = planId, SuggestedMaintenanceDate = day);
        insert line;
        return line;
    }

    private static Asset homePlan(Id accountId) {
        return [SELECT Id FROM Asset WHERE AccountId = :accountId AND Name = 'Comfort Plus'];
    }

    @IsTest
    static void statePeriodsBecomeActiveStretches() {
        List<AssetStatePeriod> periods = (List<AssetStatePeriod>) JSON.deserialize('['
            + '{"StartDate":"2026-01-01T00:00:00.000+0000","EndDate":"2026-03-31T23:59:59.000+0000","Quantity":1},'
            + '{"StartDate":"2026-04-01T00:00:00.000+0000","EndDate":"2026-10-31T23:59:59.000+0000","Quantity":1},'
            + '{"StartDate":"2026-11-01T00:00:00.000+0000","EndDate":"2027-03-31T23:59:59.000+0000","Quantity":0},'
            + '{"StartDate":"2027-04-01T00:00:00.000+0000","Quantity":1}]', List<AssetStatePeriod>.class);

        List<RLM_HVAC_Coverage.Stretch> stretches = RLM_HVAC_Coverage.stretchesFrom(periods);

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
        Asset home = addPlan(account.Id, 'Comfort Plus', 'HVAC-PLUS');
        activeFor(home.Id, new List<RLM_HVAC_Coverage.Stretch>{ stretch(today.addDays(-30), null) });
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        Id planId = [SELECT Id FROM MaintenancePlan WHERE AccountId = :account.Id].Id;
        Date nextVisit = tuneUps().firstVisit(today);
        WorkOrderLineItem line = visit(account.Id, planId, home.Id, nextVisit);

        Asset plus = addPlan(account.Id, 'Comfort Premier', 'HVAC-PREMIER');
        activeFor(home.Id, new List<RLM_HVAC_Coverage.Stretch>{ stretch(today.addDays(-30), today) });
        activeFor(plus.Id, new List<RLM_HVAC_Coverage.Stretch>{ stretch(today.addDays(1), null) });
        RLM_HVAC_Coverage.sync(new Set<Id>{ account.Id });

        Assert.areEqual(today, [SELECT EndDate FROM Entitlement WHERE AssetId = :home.Id].EndDate, 'The old coverage ends with its agreement');
        Entitlement premierCoverage = [SELECT StartDate, EndDate, RLM_HVAC_Covered_Systems__c FROM Entitlement WHERE AssetId = :plus.Id];
        Assert.areEqual(today.addDays(1), premierCoverage.StartDate);
        Assert.isNull(premierCoverage.EndDate);
        Assert.areEqual('Cooling;Heating', premierCoverage.RLM_HVAC_Covered_Systems__c);
        Assert.areEqual(plus.Id, [SELECT AssetId FROM WorkOrderLineItem WHERE Id = :line.Id].AssetId, 'The upcoming tune-up keeps its day under Premier');
        Assert.areEqual(0, [SELECT COUNT() FROM MaintenanceAsset WHERE AssetId = :home.Id], 'The old agreement stops generating visits');
        Assert.areEqual(tuneUps().firstVisit(nextVisit), [
            SELECT NextSuggestedMaintenanceDate FROM MaintenanceWorkRule WHERE ParentMaintenanceRecord.AssetId = :plus.Id
        ].NextSuggestedMaintenanceDate, 'Premier tune-ups continue the season after the carried visit');
    }

    @IsTest
    static void aPauseSplitsTheCoverageAndSkipsVisitsInTheGap() {
        workTypes();
        Account account = new Account(Name = 'Pause Home');
        insert account;
        Date today = Date.today();
        Asset home = addPlan(account.Id, 'Comfort Plus', 'HVAC-PLUS');
        activeFor(home.Id, new List<RLM_HVAC_Coverage.Stretch>{ stretch(today.addDays(-30), null) });
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        Id planId = [SELECT Id FROM MaintenancePlan WHERE AccountId = :account.Id].Id;
        Date first = tuneUps().firstVisit(today);
        Date second = first.addMonths(6);
        Date resume = second.addMonths(6);
        WorkOrderLineItem firstLine = visit(account.Id, planId, home.Id, first);
        WorkOrderLineItem secondLine = visit(account.Id, planId, home.Id, second);

        activeFor(home.Id, new List<RLM_HVAC_Coverage.Stretch>{
            stretch(today.addDays(-30), first.addDays(-1)), stretch(resume, null)
        });
        RLM_HVAC_Coverage.sync(new Set<Id>{ account.Id });

        List<Entitlement> coverage = [SELECT Name, StartDate, EndDate FROM Entitlement WHERE AssetId = :home.Id ORDER BY StartDate];
        Assert.areEqual(2, coverage.size(), 'One entitlement before the pause and one after');
        Assert.areEqual(first.addDays(-1), coverage[0].EndDate);
        Assert.areEqual(resume, coverage[1].StartDate);
        Assert.isNull(coverage[1].EndDate);
        Assert.isTrue(coverage[1].Name.endsWith('from ' + resume.format()));
        Assert.areEqual(0, [SELECT COUNT() FROM WorkOrder WHERE Id IN (:firstLine.WorkOrderId, :secondLine.WorkOrderId)],
            'Visits during the pause are removed');
        Assert.areEqual(resume, [
            SELECT NextSuggestedMaintenanceDate FROM MaintenanceWorkRule WHERE ParentMaintenanceRecord.AssetId = :home.Id
        ].NextSuggestedMaintenanceDate, 'Tune-ups resume with the agreement');
    }

    @IsTest
    static void aCancellationEndsTheCoverageAndStopsVisits() {
        Map<String, Id> types = workTypes();
        Account account = customerWithPlans();
        Date today = Date.today();
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        Id planId = [SELECT Id FROM MaintenancePlan WHERE AccountId = :account.Id].Id;
        Asset home = homePlan(account.Id);
        WorkOrderLineItem line = visit(account.Id, planId, home.Id, tuneUps().firstVisit(today));

        activeFor(home.Id, new List<RLM_HVAC_Coverage.Stretch>{ stretch(today, today.addDays(5)) });
        RLM_HVAC_Coverage.sync(new Set<Id>{ account.Id });

        Assert.areEqual(today.addDays(5), [SELECT EndDate FROM Entitlement WHERE AssetId = :home.Id].EndDate);
        Assert.areEqual(0, [SELECT COUNT() FROM WorkOrder WHERE Id = :line.WorkOrderId], 'Visits after the cancellation are removed');
        Assert.areEqual(0, [SELECT COUNT() FROM MaintenanceAsset WHERE AssetId = :home.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM MaintenanceAsset WHERE MaintenancePlanId = :planId], 'Water Heater Care keeps its visits');
        Assert.areEqual(types.get('Water Heater Flush'), [SELECT WorkTypeId FROM MaintenancePlan WHERE Id = :planId].WorkTypeId,
            'The remaining agreement leads the visits');
    }

    @IsTest
    static void syncRemovesDuplicateEntitlements() {
        workTypes();
        Account account = customerWithPlans();
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        Entitlement original = [SELECT Name, AccountId, AssetId, StartDate, RLM_HVAC_Covered_Systems__c FROM Entitlement
            WHERE AccountId = :account.Id AND Name = 'Comfort Plus coverage'];
        insert original.clone(false, true);

        RLM_HVAC_Coverage.sync(new Set<Id>{ account.Id });

        Assert.areEqual(1, [SELECT COUNT() FROM Entitlement WHERE AssetId = :original.AssetId]);
    }

    @IsTest
    static void agreementAssetChangesSyncTheCustomer() {
        workTypes();
        Account account = customerWithPlans();
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        Asset home = homePlan(account.Id);
        activeFor(home.Id, new List<RLM_HVAC_Coverage.Stretch>{ stretch(Date.today(), Date.today()) });

        Test.startTest();
        update home;
        Test.stopTest();

        Assert.areEqual(Date.today(), [SELECT EndDate FROM Entitlement WHERE AssetId = :home.Id].EndDate);
    }

    @IsTest
    static void nightlySyncCoversEveryCustomer() {
        workTypes();
        Account account = customerWithPlans();
        RLM_HVAC_Coverage.activate(new Set<Id>{ account.Id });
        Asset home = homePlan(account.Id);
        activeFor(home.Id, new List<RLM_HVAC_Coverage.Stretch>{ stretch(Date.today(), Date.today().addDays(10)) });

        Test.startTest();
        RLM_HVAC_Coverage.syncAll();
        Test.stopTest();

        Assert.areEqual(Date.today().addDays(10), [SELECT EndDate FROM Entitlement WHERE AssetId = :home.Id].EndDate);
    }

    @IsTest
    static void issuesMapToTheSystemsThatCoverThem() {
        Assert.isTrue(RLM_HVAC_Coverage.systemsForIssue('No Cool').contains('Cooling'));
        Assert.isTrue(RLM_HVAC_Coverage.systemsForIssue('No Heat').contains('Heating'));
        Assert.isTrue(RLM_HVAC_Coverage.systemsForIssue('Unknown').isEmpty());
        Assert.areEqual(4, RLM_HVAC_Coverage.responseHoursFor('HVAC-PREMIER'));
        Assert.isNull(RLM_HVAC_Coverage.responseHoursFor('NOT-A-SKU'));
    }
}
