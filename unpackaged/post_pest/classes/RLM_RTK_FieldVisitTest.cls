@IsTest
private class RLM_RTK_FieldVisitTest {
    private static WorkOrder inspectionVisit() {
        Account account = new Account(
            Name = 'Field Visit Test',
            ShippingStreet = '142 Lakeview Ct',
            ShippingCity = 'Bloomingdale',
            ShippingState = 'IL',
            ShippingPostalCode = '60108'
        );
        insert account;
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Free Pest Inspection');
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
        WorkOrder wo = inspectionVisit();
        ServiceAppointment sa = appointmentFor(wo.Id);

        RLM_RTK_FieldVisit.VisitContext ctx = RLM_RTK_FieldVisit.getContext(sa.Id);

        Assert.areEqual(wo.Id, ctx.workOrderId);
        Assert.areEqual('start', ctx.stage);
        Assert.isTrue(ctx.canInspect);
        Assert.areEqual('Field Visit Test', ctx.accountName);
        Assert.areEqual('60108', ctx.postalCode);
        Assert.areEqual('142 Lakeview Ct, Bloomingdale, IL 60108', ctx.serviceAddress);
    }

    @IsTest
    static void startInspectionIsIdempotent() {
        WorkOrder wo = inspectionVisit();

        Id first = RLM_RTK_FieldVisit.startInspection(wo.Id);
        Id second = RLM_RTK_FieldVisit.startInspection(wo.Id);

        Assert.areEqual(first, second);
        Assert.areEqual(1, [SELECT COUNT() FROM RLM_RTK_Inspection__c WHERE Account__c = :wo.AccountId]);
        RLM_RTK_FieldVisit.VisitContext ctx = RLM_RTK_FieldVisit.getContext(wo.Id);
        Assert.areEqual('walk', ctx.stage);
        Assert.areEqual(first, ctx.inspectionId);
    }

    @IsTest
    static void quotedInspectionMovesToCustomerThenOrder() {
        WorkOrder wo = inspectionVisit();
        Id inspectionId = RLM_RTK_FieldVisit.startInspection(wo.Id);
        Quote q = quoteFor(wo.AccountId);
        RLM_RTK_Inspection.markQuoted(inspectionId, q.Id, null);

        Assert.areEqual('customer', RLM_RTK_FieldVisit.getContext(wo.Id).stage);

        update new Quote(Id = q.Id, RLM_Demo_Signed_At__c = Datetime.now(), RLM_Demo_Signed_By__c = 'Test');
        RLM_RTK_FieldVisit.VisitContext ctx = RLM_RTK_FieldVisit.getContext(wo.Id);
        Assert.areEqual('order', ctx.stage);
        Assert.isTrue(ctx.signed);
        Assert.areEqual('Creating', RLM_RTK_FieldVisit.orderStatus(q.Id).status);
    }

    @IsTest
    static void existingQuoteIsReturnedInsteadOfCreatingAnother() {
        WorkOrder wo = inspectionVisit();
        Id inspectionId = RLM_RTK_FieldVisit.startInspection(wo.Id);
        Quote q = quoteFor(wo.AccountId);
        RLM_RTK_Inspection.markQuoted(inspectionId, q.Id, null);

        RLM_RTK_FieldVisit.QuoteResult result = RLM_RTK_FieldVisit.createQuote(
            wo.Id, 'RTK-ESSENTIAL', 'SingleFamily', 'Under2000', 'Light', false, false, null);

        Assert.areEqual(q.Id, result.quoteId);
    }

    @IsTest
    static void quoteNeedsAnInspection() {
        WorkOrder wo = inspectionVisit();
        try {
            RLM_RTK_FieldVisit.createQuote(wo.Id, 'RTK-ESSENTIAL', 'SingleFamily', 'Under2000', 'Light', false, false, null);
            Assert.fail('Expected an error without an inspection');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Walk the property'), e.getMessage());
        }
    }

    @IsTest
    static void unsignedQuoteCannotBeOrdered() {
        WorkOrder wo = inspectionVisit();
        Quote q = quoteFor(wo.AccountId);
        try {
            RLM_RTK_FieldVisit.placeOrder(q.Id);
            Assert.fail('Expected an error for an unsigned quote');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not signed'), e.getMessage());
        }
    }

    @IsTest
    static void draftOrderNeedsACustomerContact() {
        WorkOrder wo = inspectionVisit();
        Quote q = quoteFor(wo.AccountId);
        insert new Order(AccountId = wo.AccountId, QuoteId = q.Id, Status = 'Draft',
            EffectiveDate = Date.today(), Pricebook2Id = Test.getStandardPricebookId());
        try {
            RLM_RTK_FieldVisit.orderStatus(q.Id);
            Assert.fail('Expected an error without a contact');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Add a contact to Field Visit Test'), e.getMessage());
        }
    }

    @IsTest
    static void firstTreatmentIsBookedAtAPickedSlot() {
        insert new ServiceResource(Name = 'Field Visit Tech', RelatedRecordId = UserInfo.getUserId(),
            ResourceType = 'T', IsActive = true);
        WorkOrder wo = inspectionVisit();
        ServiceAppointment sa = new ServiceAppointment(ParentRecordId = wo.Id, EarliestStartTime = Datetime.now(),
            DueDate = Datetime.now().addDays(7), Duration = 1, DurationType = 'Hours');
        insert sa;
        Quote q = quoteFor(wo.AccountId);

        List<RLM_RTK_FieldVisit.Slot> slots = RLM_RTK_FieldVisit.treatmentSlots(sa.Id);
        Assert.areEqual(6, slots.size());
        Assert.isTrue(slots[0].startTime > Datetime.now());
        Assert.areEqual(slots[0].startTime.addHours(1), slots[0].endTime);

        RLM_RTK_FieldVisit.bookTreatment(sa.Id, slots[0].startTime, q.Id);

        ServiceAppointment booked = [
            SELECT Status, SchedStartTime, (SELECT Id FROM ServiceResources) FROM ServiceAppointment WHERE Id = :sa.Id
        ];
        Assert.areEqual('Dispatched', booked.Status);
        Assert.areEqual(slots[0].startTime, booked.SchedStartTime);
        Assert.areEqual(1, booked.ServiceResources.size());
        Assert.areNotEqual(slots[0].startTime, RLM_RTK_FieldVisit.treatmentSlots(sa.Id)[0].startTime);
    }

    @IsTest
    static void otherRecordsAreRejected() {
        WorkOrder wo = inspectionVisit();
        try {
            RLM_RTK_FieldVisit.getContext(wo.AccountId);
            Assert.fail('Expected an error for an account id');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('service appointment or work order'), e.getMessage());
        }
    }

    @IsTest
    static void uploadedPhotosLandInTheRightStage() {
        WorkOrder wo = inspectionVisit();
        Id inspectionId = RLM_RTK_FieldVisit.startInspection(wo.Id);
        RLM_RTK_Finding__c finding = new RLM_RTK_Finding__c(
            Inspection__c = inspectionId, Zone__c = 'Garage', Pest__c = 'Rodents', Severity__c = 'Light');
        insert finding;
        String data = EncodingUtil.base64Encode(Blob.valueOf('fake jpeg bytes'));

        RLM_RTK_Inspection.uploadPhoto(finding.Id, 'garage.jpg', data, 'Before');
        RLM_RTK_Inspection.uploadPhoto(finding.Id, 'garage-after.jpg', data, 'After');

        RLM_RTK_Inspection.InspectionState state = RLM_RTK_Inspection.getWorkOrderFindings(wo.Id);
        Assert.areEqual(1, state.findings[0].photos.size());
        Assert.areEqual(1, state.findings[0].afterPhotos.size());
        Assert.areEqual('garage', state.findings[0].photos[0].title);
    }
}
