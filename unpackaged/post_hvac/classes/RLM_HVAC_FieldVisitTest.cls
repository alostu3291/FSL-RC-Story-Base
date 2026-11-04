@IsTest
private class RLM_HVAC_FieldVisitTest {
    private static WorkOrder systemCheckVisit() {
        Account account = new Account(
            Name = 'Field Visit Test',
            ShippingStreet = '1240 Aurora Ave',
            ShippingCity = 'Naperville',
            ShippingState = 'IL',
            ShippingPostalCode = '60540'
        );
        insert account;
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Free System Check');
        insert wo;
        return wo;
    }

    private static ServiceAppointment appointmentFor(Id workOrderId) {
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = workOrderId,
            EarliestStartTime = Datetime.now(),
            DueDate = Datetime.now().addDays(1)
        );
        insert sa;
        return sa;
    }

    private static Quote quoteFor(Id accountId) {
        Opportunity opportunity = new Opportunity(
            Name = 'Field Visit Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = accountId
        );
        insert opportunity;
        Quote q = new Quote(Name = 'Field Visit Quote', OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId());
        insert q;
        return q;
    }

    @IsTest
    static void appointmentResolvesToItsWorkOrder() {
        WorkOrder wo = systemCheckVisit();
        ServiceAppointment sa = appointmentFor(wo.Id);

        RLM_HVAC_FieldVisit.VisitContext ctx = RLM_HVAC_FieldVisit.getContext(sa.Id);

        Assert.areEqual(wo.Id, ctx.workOrderId);
        Assert.areEqual('start', ctx.stage);
        Assert.isTrue(ctx.canAssess);
        Assert.areEqual('Field Visit Test', ctx.accountName);
        Assert.areEqual('60540', ctx.postalCode);
        Assert.areEqual('1240 Aurora Ave, Naperville, IL 60540', ctx.serviceAddress);
    }

    @IsTest
    static void startAssessmentIsIdempotent() {
        WorkOrder wo = systemCheckVisit();

        Id first = RLM_HVAC_FieldVisit.startAssessment(wo.Id);
        Id second = RLM_HVAC_FieldVisit.startAssessment(wo.Id);

        Assert.areEqual(first, second);
        Assert.areEqual(1, [SELECT COUNT() FROM RLM_HVAC_Assessment__c WHERE Account__c = :wo.AccountId]);
        RLM_HVAC_FieldVisit.VisitContext ctx = RLM_HVAC_FieldVisit.getContext(wo.Id);
        Assert.areEqual('walk', ctx.stage);
        Assert.areEqual(first, ctx.assessmentId);
    }

    @IsTest
    static void quotedSystemCheckMovesToCustomerThenOrder() {
        WorkOrder wo = systemCheckVisit();
        Id assessmentId = RLM_HVAC_FieldVisit.startAssessment(wo.Id);
        Quote q = quoteFor(wo.AccountId);
        RLM_HVAC_Assessment.markQuoted(assessmentId, q.Id, null);

        Assert.areEqual('customer', RLM_HVAC_FieldVisit.getContext(wo.Id).stage);

        update new Quote(Id = q.Id, RLM_Demo_Signed_At__c = Datetime.now(), RLM_Demo_Signed_By__c = 'Test');
        RLM_HVAC_FieldVisit.VisitContext ctx = RLM_HVAC_FieldVisit.getContext(wo.Id);
        Assert.areEqual('order', ctx.stage);
        Assert.isTrue(ctx.signed);
        Assert.areEqual('Creating', RLM_HVAC_FieldVisit.orderStatus(q.Id).status);
    }

    @IsTest
    static void existingQuoteIsReturnedInsteadOfCreatingAnother() {
        WorkOrder wo = systemCheckVisit();
        Id assessmentId = RLM_HVAC_FieldVisit.startAssessment(wo.Id);
        Quote q = quoteFor(wo.AccountId);
        RLM_HVAC_Assessment.markQuoted(assessmentId, q.Id, null);

        RLM_HVAC_FieldVisit.QuoteResult result = RLM_HVAC_FieldVisit.createQuote(
            wo.Id, 'HVAC-BASIC', 'AcFurnace', '6to10', 1, false, false, null, null);

        Assert.areEqual(q.Id, result.quoteId);
    }

    private static void replacementProducts() {
        Map<String, Decimal> prices = new Map<String, Decimal>{
            'HVAC-REPL-GOOD' => 8900, 'HVAC-REPL-BETTER' => 11500, 'HVAC-REPL-BEST' => 14800
        };
        List<Product2> products = new List<Product2>();
        for (String sku : prices.keySet()) {
            products.add(new Product2(Name = sku, StockKeepingUnit = sku, IsActive = true));
        }
        insert products;
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Product2 p : products) {
            entries.add(new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = p.Id,
                UnitPrice = prices.get(p.StockKeepingUnit), IsActive = true));
        }
        insert entries;
    }

    @IsTest
    static void replacementOptionsAreGoodBetterBest() {
        replacementProducts();
        WorkOrder wo = systemCheckVisit();
        Id assessmentId = RLM_HVAC_FieldVisit.startAssessment(wo.Id);
        insert new RLM_HVAC_Finding__c(Assessment__c = assessmentId, Equipment__c = 'Furnace', Component__c = 'Heat Exchanger',
            Condition__c = 'Worn', Urgency__c = 'Monitor', Install_Year__c = Date.today().year() - 14);

        RLM_HVAC_FieldVisit.ReplacementOptions options = RLM_HVAC_FieldVisit.getReplacementOptions(wo.Id);

        Assert.areEqual(3, options.options.size());
        Assert.areEqual('Good', options.options[0].tier);
        Assert.areEqual('Best', options.options[2].tier);
        Assert.isTrue(options.options[1].suggested, 'Better is the suggested option');
        Assert.areEqual(3, options.options[0].features.size());
        Assert.isTrue(options.options[0].price > 0);
        Assert.areEqual(14, options.oldestAge);
        Assert.isTrue(options.recommended);
        Assert.isTrue(options.reason.contains('14 years old'), options.reason);
        Assert.isNull(options.quoteId);
    }

    @IsTest
    static void existingReplacementQuoteIsReturned() {
        WorkOrder wo = systemCheckVisit();
        Id assessmentId = RLM_HVAC_FieldVisit.startAssessment(wo.Id);
        Quote q = quoteFor(wo.AccountId);
        update new RLM_HVAC_Assessment__c(Id = assessmentId, Replacement_Quote__c = q.Id, Replacement_Sku__c = 'HVAC-REPL-BEST');

        RLM_HVAC_FieldVisit.QuoteResult result = RLM_HVAC_FieldVisit.createReplacementQuote(wo.Id, 'HVAC-REPL-GOOD');

        Assert.areEqual(q.Id, result.quoteId);
        try {
            RLM_HVAC_FieldVisit.createReplacementQuote(wo.Id, 'HVAC-BASIC');
            Assert.fail('Expected an error for a SKU that is not a replacement');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Choose a replacement'), e.getMessage());
        }
    }

    @IsTest
    static void replacementNeedsASystemCheck() {
        WorkOrder wo = systemCheckVisit();
        try {
            RLM_HVAC_FieldVisit.getReplacementOptions(wo.Id);
            Assert.fail('Expected an error without a system check');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Check the system'), e.getMessage());
        }
    }

    @IsTest
    static void quoteNeedsASystemCheck() {
        WorkOrder wo = systemCheckVisit();
        try {
            RLM_HVAC_FieldVisit.createQuote(wo.Id, 'HVAC-BASIC', 'AcFurnace', '6to10', 1, false, false, null, null);
            Assert.fail('Expected an error without a system check');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Check the system'), e.getMessage());
        }
    }

    @IsTest
    static void unsignedQuoteCannotBeOrdered() {
        WorkOrder wo = systemCheckVisit();
        Quote q = quoteFor(wo.AccountId);
        try {
            RLM_HVAC_FieldVisit.placeOrder(q.Id);
            Assert.fail('Expected an error for an unsigned quote');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not signed'), e.getMessage());
        }
    }

    @IsTest
    static void draftOrderNeedsACustomerContact() {
        WorkOrder wo = systemCheckVisit();
        Quote q = quoteFor(wo.AccountId);
        insert new Order(AccountId = wo.AccountId, QuoteId = q.Id, Status = 'Draft',
            EffectiveDate = Date.today(), Pricebook2Id = Test.getStandardPricebookId());
        try {
            RLM_HVAC_FieldVisit.orderStatus(q.Id);
            Assert.fail('Expected an error without a contact');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Add a contact to Field Visit Test'), e.getMessage());
        }
    }

    @IsTest
    static void initialTuneUpIsBookedAtAPickedSlot() {
        insert new ServiceResource(Name = 'Field Visit Tech', RelatedRecordId = UserInfo.getUserId(),
            ResourceType = 'T', IsActive = true);
        WorkOrder wo = systemCheckVisit();
        ServiceAppointment sa = new ServiceAppointment(ParentRecordId = wo.Id, EarliestStartTime = Datetime.now(),
            DueDate = Datetime.now().addDays(7), Duration = 1, DurationType = 'Hours');
        insert sa;
        Quote q = quoteFor(wo.AccountId);

        List<RLM_HVAC_FieldVisit.Slot> slots = RLM_HVAC_FieldVisit.tuneUpSlots(sa.Id);
        Assert.areEqual(6, slots.size());
        Assert.isTrue(slots[0].startTime > Datetime.now());
        Assert.areEqual(slots[0].startTime.addHours(1), slots[0].endTime);

        RLM_HVAC_FieldVisit.bookTuneUp(sa.Id, slots[0].startTime, q.Id);

        ServiceAppointment booked = [
            SELECT Status, SchedStartTime, (SELECT Id FROM ServiceResources) FROM ServiceAppointment WHERE Id = :sa.Id
        ];
        Assert.areEqual('Dispatched', booked.Status);
        Assert.areEqual(slots[0].startTime, booked.SchedStartTime);
        Assert.areEqual(1, booked.ServiceResources.size());
        Assert.areNotEqual(slots[0].startTime, RLM_HVAC_FieldVisit.tuneUpSlots(sa.Id)[0].startTime);
    }

    @IsTest
    static void completingTheVisitClosesAppointmentAndWorkOrder() {
        WorkOrder wo = systemCheckVisit();
        ServiceAppointment sa = appointmentFor(wo.Id);

        String completedNumber = RLM_HVAC_FieldVisit.completeVisit(sa.Id);

        WorkOrder done = [SELECT WorkOrderNumber, Status FROM WorkOrder WHERE Id = :wo.Id];
        Assert.areEqual(done.WorkOrderNumber, completedNumber);
        Assert.areEqual('Completed', done.Status);
        ServiceAppointment closed = [SELECT Status, ActualEndTime FROM ServiceAppointment WHERE Id = :sa.Id];
        Assert.areEqual('Completed', closed.Status);
        Assert.isNotNull(closed.ActualEndTime);
    }

    @IsTest
    static void startingTheSystemCheckStartsTheAppointmentAndWorkOrder() {
        WorkOrder wo = systemCheckVisit();
        ServiceAppointment sa = appointmentFor(wo.Id);
        Assert.isNull(RLM_HVAC_FieldVisit.getVisitTiming(sa.Id).startedAt);

        RLM_HVAC_FieldVisit.startAssessment(wo.Id);

        ServiceAppointment started = [SELECT Status, ActualStartTime FROM ServiceAppointment WHERE Id = :sa.Id];
        Assert.areEqual('In Progress', started.Status);
        Assert.isNotNull(started.ActualStartTime);
        WorkOrder visit = [SELECT Status, StartDate FROM WorkOrder WHERE Id = :wo.Id];
        Assert.areEqual('In Progress', visit.Status);
        Assert.areEqual(started.ActualStartTime, visit.StartDate);
        Assert.areEqual(started.ActualStartTime, RLM_HVAC_FieldVisit.getVisitTiming(wo.Id).startedAt);
        Assert.isNull(RLM_HVAC_FieldVisit.getVisitTiming(wo.Id).response, 'A system check has no response time');
    }

    @IsTest
    static void startingAVisitKeepsTheFirstStartAndCompletionRecordsTheEnd() {
        WorkOrder wo = systemCheckVisit();
        ServiceAppointment sa = appointmentFor(wo.Id);
        update new ServiceAppointment(Id = sa.Id, Status = 'In Progress', ActualStartTime = Datetime.now().addMinutes(-30));
        Datetime arrived = [SELECT ActualStartTime FROM ServiceAppointment WHERE Id = :sa.Id].ActualStartTime;

        RLM_HVAC_FieldVisit.VisitTiming timing = RLM_HVAC_FieldVisit.startVisit(sa.Id);
        Assert.areEqual(arrived, timing.startedAt);
        Assert.areEqual(sa.Id, timing.appointmentId);
        Assert.areEqual(arrived, [SELECT StartDate FROM WorkOrder WHERE Id = :wo.Id].StartDate);

        RLM_HVAC_FieldVisit.completeVisit(wo.Id);
        ServiceAppointment done = [SELECT ActualStartTime, ActualEndTime, ActualDuration FROM ServiceAppointment WHERE Id = :sa.Id];
        Assert.areEqual(arrived, done.ActualStartTime);
        Assert.isTrue(done.ActualDuration >= 29, String.valueOf(done.ActualDuration));
        WorkOrder closed = [SELECT Status, StartDate, EndDate FROM WorkOrder WHERE Id = :wo.Id];
        Assert.areEqual('Completed', closed.Status);
        Assert.areEqual(arrived, closed.StartDate);
        Assert.areEqual(done.ActualEndTime, closed.EndDate);
        Assert.isTrue(RLM_HVAC_FieldVisit.getVisitTiming(wo.Id).completed);
    }

    @IsTest
    static void otherRecordsAreRejected() {
        WorkOrder wo = systemCheckVisit();
        try {
            RLM_HVAC_FieldVisit.getContext(wo.AccountId);
            Assert.fail('Expected an error for an account id');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('service appointment or work order'), e.getMessage());
        }
    }

    @IsTest
    static void uploadedPhotosLandInTheRightStage() {
        WorkOrder wo = systemCheckVisit();
        Id assessmentId = RLM_HVAC_FieldVisit.startAssessment(wo.Id);
        RLM_HVAC_Finding__c finding = new RLM_HVAC_Finding__c(
            Assessment__c = assessmentId, Equipment__c = 'Outdoor Unit', Component__c = 'Capacitor', Urgency__c = 'Monitor');
        insert finding;
        String data = EncodingUtil.base64Encode(Blob.valueOf('fake jpeg bytes'));

        RLM_HVAC_Assessment.uploadPhoto(finding.Id, 'condenser.jpg', data, 'Before');
        RLM_HVAC_Assessment.uploadPhoto(finding.Id, 'condenser-after.jpg', data, 'After');

        RLM_HVAC_Assessment.AssessmentState state = RLM_HVAC_Assessment.getWorkOrderFindings(wo.Id);
        Assert.areEqual(1, state.findings[0].photos.size());
        Assert.areEqual(1, state.findings[0].afterPhotos.size());
        Assert.areEqual('condenser', state.findings[0].photos[0].title);
    }
}
