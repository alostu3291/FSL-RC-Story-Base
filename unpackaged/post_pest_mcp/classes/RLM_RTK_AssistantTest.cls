@IsTest
private class RLM_RTK_AssistantTest {
    private static final TimeZone CENTRAL = TimeZone.getTimeZone('America/Chicago');

    @TestSetup
    static void technicianAndTerritory() {
        ServiceResource tech = new ServiceResource(Name = 'Assistant Tech', RelatedRecordId = UserInfo.getUserId(),
            ResourceType = 'T', IsActive = true);
        insert tech;
        OperatingHours hours = new OperatingHours(Name = 'Assistant Test Hours', TimeZone = 'America/Chicago');
        insert hours;
        ServiceTerritory territory = new ServiceTerritory(Name = RLM_RTK_Assistant.TERRITORY,
            OperatingHoursId = hours.Id, IsActive = true);
        insert territory;
        insert new ServiceTerritoryMember(ServiceResourceId = tech.Id, ServiceTerritoryId = territory.Id,
            EffectiveStartDate = Datetime.now().addDays(-1), TerritoryType = 'P');
        insert new List<WorkType>{
            new WorkType(Name = 'Pest Inspection', EstimatedDuration = 1, DurationType = 'Hours'),
            new WorkType(Name = 'Pest Re-service', EstimatedDuration = 1, DurationType = 'Hours')
        };
    }

    private static RLM_RTK_Assistant.Caller sarah() {
        RLM_RTK_Assistant.Caller caller = new RLM_RTK_Assistant.Caller();
        caller.name = 'Sarah Mitchell';
        caller.street = '218 Maple Ridge Dr';
        caller.phone = '(630) 555-0188';
        caller.description = 'Ants in the kitchen.';
        return caller;
    }

    @IsTest
    static void callerGetsADispatchedInspection() {
        Date tomorrow = Date.today().addDays(1);
        RLM_RTK_Assistant.Booking booking = RLM_RTK_Assistant.bookInspection(sarah(), tomorrow, 10);

        Account account = [SELECT Name, RLM_RTK_Demo_Run__c, ShippingPostalCode FROM Account WHERE Id = :booking.accountId];
        Assert.isTrue(booking.newCustomer);
        Assert.isNotNull(account.RLM_RTK_Demo_Run__c);
        Assert.areEqual('60108', account.ShippingPostalCode);
        Assert.areEqual(1, [SELECT COUNT() FROM Contact WHERE AccountId = :booking.accountId AND Phone = '(630) 555-0188']);
        ServiceAppointment sa = [
            SELECT Status, SchedStartTime, (SELECT Id FROM ServiceResources) FROM ServiceAppointment WHERE Id = :booking.appointmentId
        ];
        Assert.areEqual('Dispatched', sa.Status);
        Assert.areEqual(RLM_RTK_Assistant.zonedStart(tomorrow, 10, CENTRAL), sa.SchedStartTime);
        Assert.areEqual(1, sa.ServiceResources.size());
        Assert.areEqual('Pest Inspection', booking.workType);
    }

    @IsTest
    static void callingAgainMovesTheSameVisit() {
        RLM_RTK_Assistant.Booking first = RLM_RTK_Assistant.bookInspection(sarah(), Date.today().addDays(1), 10);
        RLM_RTK_Assistant.Booking second = RLM_RTK_Assistant.bookInspection(sarah(), Date.today().addDays(2), 14);

        Assert.areEqual(first.workOrderId, second.workOrderId);
        Assert.areEqual(first.appointmentId, second.appointmentId);
        Assert.isFalse(second.newCustomer == true);
        Assert.areEqual(RLM_RTK_Assistant.zonedStart(Date.today().addDays(2), 14, CENTRAL), second.startTime);
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = 'Sarah Mitchell']);
    }

    @IsTest
    static void customersWithPlansAreSentToReservice() {
        RLM_RTK_Assistant.Booking booking = RLM_RTK_Assistant.bookInspection(sarah(), Date.today().addDays(1), 10);
        Product2 plan = new Product2(Name = 'Home Protection Plan', StockKeepingUnit = 'RTK-TEST-PLAN', IsActive = true);
        insert plan;
        insert new Asset(Name = 'Home Protection Plan', AccountId = booking.accountId, Product2Id = plan.Id);
        try {
            RLM_RTK_Assistant.bookInspection(sarah(), Date.today().addDays(1), 11);
            Assert.fail('Expected a customer with a plan to be refused');
        } catch (RLM_RTK_Assistant.AssistantException e) {
            Assert.isTrue(e.getMessage().contains('re-service'), e.getMessage());
        }
    }

    @IsTest
    static void pastTimesAndMissingDetailsAreRefused() {
        try {
            RLM_RTK_Assistant.bookInspection(sarah(), Date.today().addDays(-1), 10);
            Assert.fail('Expected a past time to be refused');
        } catch (RLM_RTK_Assistant.AssistantException e) {
            Assert.isTrue(e.getMessage().contains('future'), e.getMessage());
        }
        try {
            RLM_RTK_Assistant.bookInspection(new RLM_RTK_Assistant.Caller(), Date.today().addDays(1), 10);
            Assert.fail('Expected a caller without details to be refused');
        } catch (RLM_RTK_Assistant.AssistantException e) {
            Assert.isTrue(e.getMessage().contains('name and a street'), e.getMessage());
        }
    }

    @IsTest
    static void scheduleListsTheDaysVisits() {
        Date tomorrow = Date.today().addDays(1);
        RLM_RTK_Assistant.Booking booking = RLM_RTK_Assistant.bookInspection(sarah(), tomorrow, 9);

        List<RLM_RTK_Assistant.Visit> visits = RLM_RTK_Assistant.schedule(tomorrow);
        Assert.areEqual(1, visits.size());
        Assert.areEqual(booking.appointmentId, visits[0].appointmentId);
        Assert.areEqual('Sarah Mitchell', visits[0].accountName);
        Assert.areEqual('218 Maple Ridge Dr, Bloomingdale, IL 60108', visits[0].address);
        Assert.areEqual(0, RLM_RTK_Assistant.schedule(tomorrow.addDays(1)).size());
    }

    @IsTest
    static void reserviceIsBookedWithTheReportedPest() {
        RLM_RTK_Assistant.Booking inspection = RLM_RTK_Assistant.bookInspection(sarah(), Date.today().addDays(1), 10);

        RLM_RTK_Assistant.Booking booking = RLM_RTK_Assistant.bookReservice(inspection.accountId, 'Ants', null,
            Date.today().addDays(2), 13);

        WorkOrder wo = [SELECT RLM_RTK_Reported_Pest__c, WorkType.Name FROM WorkOrder WHERE Id = :booking.workOrderId];
        Assert.areEqual('Ants', wo.RLM_RTK_Reported_Pest__c);
        Assert.areEqual('Pest Re-service', wo.WorkType.Name);
        Assert.areEqual(booking.workOrderId,
            RLM_RTK_Assistant.bookReservice(inspection.accountId, 'Spiders', 'Webs on the porch.', Date.today().addDays(2), 15).workOrderId);
    }

    @IsTest
    static void summaryAndSearchSkipArchivedRuns() {
        RLM_RTK_Assistant.Booking booking = RLM_RTK_Assistant.bookInspection(sarah(), Date.today().addDays(1), 10);

        RLM_RTK_Assistant.CustomerSummary summary = RLM_RTK_Assistant.customerSummary(booking.accountId);
        Assert.areEqual('Sarah Mitchell', summary.name);
        Assert.areEqual(1, summary.openVisits.size());
        Assert.areEqual(0, summary.plans.size());
        Assert.areEqual(1, RLM_RTK_Assistant.findCustomers('Mitchell').size());

        RLM_RTK_DemoReset.Result reset = RLM_RTK_DemoReset.reset('Sarah Mitchell');

        Assert.areEqual(1, reset.archived.size());
        Assert.isTrue(reset.archived[0].startsWith(RLM_RTK_DemoReset.ARCHIVE_PREFIX + 'Sarah Mitchell'));
        Assert.areEqual(1, reset.workOrdersCanceled);
        Assert.areEqual(1, reset.appointmentsCanceled);
        Assert.areEqual(0, RLM_RTK_Assistant.findCustomers('Mitchell').size());
        Assert.areEqual(0, RLM_RTK_Assistant.schedule(Date.today().addDays(1)).size());
        Assert.isTrue(RLM_RTK_Assistant.bookInspection(sarah(), Date.today().addDays(1), 10).newCustomer);
    }

    @IsTest
    static void resetLeavesCustomersTheAssistantDidNotCreate() {
        insert new Account(Name = 'Sarah Mitchell');

        Assert.areEqual(0, RLM_RTK_DemoReset.reset('Sarah Mitchell').archived.size());
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = 'Sarah Mitchell']);
    }

    @IsTest
    static void hoursAreOnTheTerritoryClock() {
        Assert.areEqual(Datetime.newInstanceGmt(2026, 1, 15, 16, 0, 0),
            RLM_RTK_Assistant.zonedStart(Date.newInstance(2026, 1, 15), 10, CENTRAL));
        Assert.areEqual(Datetime.newInstanceGmt(2026, 7, 15, 15, 0, 0),
            RLM_RTK_Assistant.zonedStart(Date.newInstance(2026, 7, 15), 10, CENTRAL));
    }
}
