/**
 * Server side of the Check & Quote quick action that runs from a Service Appointment or
 * Work Order in the Field Service mobile app: start the system check, create the quote,
 * generate the proposal, then turn the signed quote into an activated order so fulfillment
 * creates the Initial Tune-up work order. Each step is safe to call again when the technician
 * reopens the action.
 */
public with sharing class RLM_HVAC_FieldVisit {
    public static final String PROPOSAL_TEMPLATE = 'RLM_HVAC_Proposal';
    public static final String REPLACEMENT_PROPOSAL_TEMPLATE = 'RLM_HVAC_Replacement_Proposal';

    public class VisitContext {
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public Boolean canAssess;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String serviceAddress;
        @AuraEnabled public String postalCode;
        @AuraEnabled public Id assessmentId;
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public Boolean signed = false;
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        /** start, walk, customer, order or done */
        @AuraEnabled public String stage;
    }

    public class QuoteResult {
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String zoneCode;
        @AuraEnabled public Decimal zoneMultiplier;
        @AuraEnabled public String message;
    }

    public class ProposalStatus {
        @AuraEnabled public Id processId;
        /** Generating, Ready or Failed */
        @AuraEnabled public String status;
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public String title;
        @AuraEnabled public String message;
    }

    public class OrderStatus {
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
        @AuraEnabled public Id tuneUpWorkOrderId;
        @AuraEnabled public String tuneUpWorkOrderNumber;
        @AuraEnabled public Datetime tuneUpScheduledStart;
        @AuraEnabled public Id tuneUpAppointmentId;
    }

    public class Slot {
        @AuraEnabled public Datetime startTime;
        @AuraEnabled public Datetime endTime;
    }

    @AuraEnabled
    public static VisitContext getContext(Id recordId) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            VisitContext ctx = new VisitContext();
            ctx.workOrderId = wo.Id;
            ctx.workOrderNumber = wo.WorkOrderNumber;
            ctx.canAssess = wo.RLM_Order__c == null && wo.AccountId != null;
            ctx.accountId = wo.AccountId;
            ctx.accountName = wo.Account?.Name;
            ctx.postalCode = String.isNotBlank(wo.PostalCode) ? wo.PostalCode : wo.Account?.ShippingPostalCode;
            ctx.serviceAddress = String.isNotBlank(wo.Street)
                ? joinAddress(wo.Street, wo.City, wo.State, wo.PostalCode)
                : joinAddress(wo.Account?.ShippingStreet, wo.Account?.ShippingCity, wo.Account?.ShippingState,
                    wo.Account?.ShippingPostalCode);
            ctx.assessmentId = wo.RLM_HVAC_Assessment__c;
            ctx.stage = 'start';
            if (ctx.assessmentId == null) {
                return ctx;
            }
            ctx.stage = 'walk';
            ctx.quoteId = wo.RLM_HVAC_Assessment__r.Quote__c;
            if (ctx.quoteId == null) {
                return ctx;
            }
            Quote q = [SELECT QuoteNumber, RLM_Demo_Signed_At__c FROM Quote WHERE Id = :ctx.quoteId];
            ctx.quoteNumber = q.QuoteNumber;
            ctx.signed = q.RLM_Demo_Signed_At__c != null;
            ctx.stage = ctx.signed ? 'order' : 'customer';
            List<Order> orders = ordersFor(ctx.quoteId);
            if (!orders.isEmpty()) {
                ctx.orderId = orders[0].Id;
                ctx.orderNumber = orders[0].OrderNumber;
                ctx.stage = 'done';
            }
            return ctx;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public class VisitTiming {
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public Id appointmentId;
        @AuraEnabled public String appointmentNumber;
        @AuraEnabled public Datetime startedAt;
        @AuraEnabled public Boolean completed = false;
        @AuraEnabled public ResponseCommitment response;
    }

    /** The covered service call's Priority Response milestone, if the work order has one. */
    public class ResponseCommitment {
        @AuraEnabled public String agreementName;
        @AuraEnabled public String reportedIssue;
        @AuraEnabled public String priority;
        /** Response window the agreement promises, in service hours. */
        @AuraEnabled public Integer responseHours;
        @AuraEnabled public Datetime requestedAt;
        @AuraEnabled public Datetime dueBy;
        @AuraEnabled public Datetime metAt;
        @AuraEnabled public Boolean violated = false;
    }

    /** When the technician started this visit, if they have. */
    @AuraEnabled
    public static VisitTiming getVisitTiming(Id recordId) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            return timingFor(wo, appointmentFor(recordId, wo.Id));
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Starts the visit: the appointment goes In Progress with its actual start time, and the work
     * order goes In Progress with its start date. Calling it again keeps the first start.
     */
    @AuraEnabled
    public static VisitTiming startVisit(Id recordId) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            ServiceAppointment sa = start(wo, appointmentFor(recordId, wo.Id));
            return timingFor(workOrderFor(wo.Id), sa);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static ServiceAppointment start(WorkOrder wo, ServiceAppointment sa) {
        Datetime now = Datetime.now();
        if (sa != null && !FINISHED.contains(sa.StatusCategory)) {
            Boolean changed = false;
            if (sa.StatusCategory != 'InProgress') {
                sa.Status = 'In Progress';
                changed = true;
            }
            if (sa.ActualStartTime == null) {
                sa.ActualStartTime = now;
                changed = true;
            }
            if (changed) {
                update sa;
            }
        }
        Datetime startedAt = sa?.ActualStartTime ?? now;
        if (wo.StatusCategory == 'New' || wo.StartDate == null) {
            WorkOrder started = new WorkOrder(Id = wo.Id);
            if (wo.StatusCategory == 'New') {
                started.Status = 'In Progress';
            }
            if (wo.StartDate == null) {
                started.StartDate = startedAt;
            }
            update started;
        }
        return sa;
    }

    private static final Set<String> FINISHED = new Set<String>{ 'Completed', 'Canceled', 'CannotComplete' };

    /** The appointment the action was opened from, else the user's open one on the work order, else its first open one. */
    private static ServiceAppointment appointmentFor(Id recordId, Id workOrderId) {
        Set<Id> mine = new Set<Id>();
        for (AssignedResource ar : [
            SELECT ServiceAppointmentId FROM AssignedResource
            WHERE ServiceAppointment.ParentRecordId = :workOrderId AND ServiceResource.RelatedRecordId = :UserInfo.getUserId()
        ]) {
            mine.add(ar.ServiceAppointmentId);
        }
        ServiceAppointment first;
        ServiceAppointment firstOpen;
        ServiceAppointment myOpen;
        for (ServiceAppointment sa : [
            SELECT Id, AppointmentNumber, Status, StatusCategory, ActualStartTime, ActualEndTime
            FROM ServiceAppointment WHERE ParentRecordId = :workOrderId
            ORDER BY SchedStartTime ASC NULLS LAST, CreatedDate ASC
        ]) {
            if (sa.Id == recordId) {
                return sa;
            }
            first = first ?? sa;
            if (!FINISHED.contains(sa.StatusCategory)) {
                firstOpen = firstOpen ?? sa;
                if (myOpen == null && mine.contains(sa.Id)) {
                    myOpen = sa;
                }
            }
        }
        return myOpen ?? firstOpen ?? first;
    }

    private static VisitTiming timingFor(WorkOrder wo, ServiceAppointment sa) {
        VisitTiming t = new VisitTiming();
        t.workOrderId = wo.Id;
        t.appointmentId = sa?.Id;
        t.appointmentNumber = sa?.AppointmentNumber;
        t.startedAt = sa?.ActualStartTime ?? (wo.StatusCategory == 'New' ? null : wo.StartDate);
        t.completed = wo.StatusCategory == 'Completed' || wo.StatusCategory == 'Closed';
        List<EntityMilestone> milestones = [
            SELECT StartDate, TargetDate, CompletionDate, IsViolated
            FROM EntityMilestone
            WHERE ParentEntityId = :wo.Id AND MilestoneType.Name = :RLM_HVAC_Coverage.RESPONSE_MILESTONE
            ORDER BY StartDate DESC
            LIMIT 1
        ];
        if (!milestones.isEmpty()) {
            EntityMilestone m = milestones[0];
            WorkOrder call = [
                SELECT Priority, Entitlement.Name, Entitlement.Asset.Product2.StockKeepingUnit, RLM_HVAC_Reported_Issue__c
                FROM WorkOrder WHERE Id = :wo.Id
            ];
            t.response = new ResponseCommitment();
            t.response.agreementName = call.Entitlement?.Name;
            t.response.reportedIssue = call.RLM_HVAC_Reported_Issue__c;
            t.response.priority = call.Priority;
            t.response.responseHours = RLM_HVAC_Coverage.responseHoursFor(call.Entitlement?.Asset?.Product2?.StockKeepingUnit);
            t.response.requestedAt = m.StartDate;
            t.response.dueBy = m.TargetDate;
            t.response.metAt = m.CompletionDate;
            t.response.violated = m.IsViolated;
        }
        return t;
    }

    /** Starts the visit, then creates the system check and links it to the work order, or returns the existing one. */
    @AuraEnabled
    public static Id startAssessment(Id workOrderId) {
        try {
            WorkOrder wo = workOrderFor(workOrderId);
            if (wo.RLM_HVAC_Assessment__c == null && (wo.RLM_Order__c != null || wo.AccountId == null)) {
                throw new VisitException('Check & Quote runs from a System Check visit, not a tune-up or repair work order.');
            }
            start(wo, appointmentFor(workOrderId, wo.Id));
            if (wo.RLM_HVAC_Assessment__c != null) {
                return wo.RLM_HVAC_Assessment__c;
            }
            RLM_HVAC_Assessment__c assessment = new RLM_HVAC_Assessment__c(
                Account__c = wo.AccountId,
                Status__c = 'In Progress',
                System_Type__c = 'AcFurnace',
                System_Count__c = 1
            );
            insert assessment;
            update new WorkOrder(Id = wo.Id, RLM_HVAC_Assessment__c = assessment.Id);
            return assessment.Id;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static QuoteResult createQuote(
        Id workOrderId,
        String planSku,
        String systemType,
        String equipmentAge,
        Integer systemCount,
        Boolean includeIaq,
        Boolean includeWaterHeater,
        String repairSkus,
        String overrideReason
    ) {
        try {
            WorkOrder wo = workOrderFor(workOrderId);
            if (wo.RLM_HVAC_Assessment__c == null) {
                throw new VisitException('Check the system before creating the quote.');
            }
            if (wo.RLM_HVAC_Assessment__r.Quote__c != null) {
                return quoteResult(wo.RLM_HVAC_Assessment__r.Quote__c, 'Quote already created for this system check.');
            }
            RLM_HVAC_FieldQuote.Request request = new RLM_HVAC_FieldQuote.Request();
            request.accountId = wo.AccountId;
            request.planSku = planSku;
            request.systemType = systemType;
            request.equipmentAge = equipmentAge;
            request.systemCount = systemCount;
            request.includeIaq = includeIaq;
            request.includeWaterHeater = includeWaterHeater;
            request.repairSkus = repairSkus;
            request.assessmentId = wo.RLM_HVAC_Assessment__c;
            request.overrideReason = overrideReason;
            RLM_HVAC_FieldQuote.Response response = RLM_HVAC_FieldQuote.createQuote(request);
            if (response.success != true) {
                throw new VisitException(response.message);
            }
            QuoteResult result = quoteResult(response.quoteId, response.message);
            result.zoneCode = response.zoneCode;
            result.zoneMultiplier = response.zoneMultiplier;
            return result;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** One good / better / best replacement system, priced for the home's location. */
    public class ReplacementOption {
        @AuraEnabled public String sku;
        @AuraEnabled public String tier;
        @AuraEnabled public String name;
        @AuraEnabled public String headline;
        @AuraEnabled public List<String> features;
        @AuraEnabled public Decimal price;
        @AuraEnabled public Boolean suggested = false;
    }

    public class ReplacementOptions {
        @AuraEnabled public Id assessmentId;
        @AuraEnabled public String assessmentName;
        @AuraEnabled public Integer oldestAge;
        @AuraEnabled public Boolean recommended = false;
        @AuraEnabled public String reason;
        @AuraEnabled public String zoneCode;
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String chosenSku;
        @AuraEnabled public List<ReplacementOption> options = new List<ReplacementOption>();
    }

    public static final String REPLACEMENT_GOOD = 'HVAC-REPL-GOOD';
    public static final String REPLACEMENT_BETTER = 'HVAC-REPL-BETTER';
    public static final String REPLACEMENT_BEST = 'HVAC-REPL-BEST';

    /** Product SKUs are unique org-wide, so tests use suffixed SKUs that can't collide with the catalog. */
    @TestVisible
    private static String skuSuffix = '';

    /** Tier, headline and features for each replacement SKU, in the order they are shown. */
    private static final List<List<String>> REPLACEMENTS = new List<List<String>>{
        new List<String>{ REPLACEMENT_GOOD, 'Good', 'Dependable single-stage heat pump',
            '14.3 SEER2 single-stage heat pump with 80% furnace backup|10-year parts warranty|Installed in one day' },
        new List<String>{ REPLACEMENT_BETTER, 'Better', 'Quieter two-stage heat pump',
            '16 SEER2 two-stage heat pump with 96% furnace backup|More even temperatures and lower bills|10-year parts and 2-year labor warranty' },
        new List<String>{ REPLACEMENT_BEST, 'Best', 'Variable-speed heat pump',
            '18 SEER2 variable-speed heat pump with 96% furnace backup|Smart thermostat included|10-year parts and labor warranty' }
    };

    /** Good / better / best replacement options for the system check on this visit. */
    @AuraEnabled
    public static ReplacementOptions getReplacementOptions(Id recordId) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            if (wo.RLM_HVAC_Assessment__c == null) {
                throw new VisitException('Check the system before showing replacement options.');
            }
            RLM_HVAC_Assessment.AssessmentState state = RLM_HVAC_Assessment.getState(wo.RLM_HVAC_Assessment__c);
            RLM_HVAC_Assessment__c assessment = [
                SELECT Name, Replacement_Quote__c, Replacement_Quote__r.QuoteNumber, Replacement_Sku__c
                FROM RLM_HVAC_Assessment__c WHERE Id = :wo.RLM_HVAC_Assessment__c
            ];
            ReplacementOptions result = new ReplacementOptions();
            result.assessmentId = wo.RLM_HVAC_Assessment__c;
            result.assessmentName = assessment.Name;
            result.quoteId = assessment.Replacement_Quote__c;
            result.quoteNumber = assessment.Replacement_Quote__r?.QuoteNumber;
            result.chosenSku = assessment.Replacement_Sku__c;
            RLM_HVAC_Assessment.Recommendation rec = state.recommendation;
            if (rec != null) {
                result.oldestAge = rec.oldestAge;
                result.recommended = rec.replacementRecommended == true;
            }
            result.reason = result.oldestAge == null
                ? 'Compare replacement options with the cost of repairs.'
                : 'The oldest equipment is ' + result.oldestAge + ' years old'
                    + (result.recommended ? ', near the end of its life.' : '.');

            RLM_HVAC_ZonePricing.ZoneResult zone = RLM_HVAC_ZonePricing.resolve(wo.Account.ShippingPostalCode);
            result.zoneCode = zone.zoneCode;
            Map<String, PricebookEntry> entries = replacementEntries();
            for (List<String> r : REPLACEMENTS) {
                PricebookEntry entry = entries.get(r[0]);
                if (entry == null) {
                    continue;
                }
                ReplacementOption option = new ReplacementOption();
                option.sku = r[0];
                option.tier = r[1];
                option.headline = r[2];
                option.features = r[3].split('\\|');
                option.name = entry.Product2.Name;
                option.price = RLM_HVAC_ZonePricing.apply(entry.UnitPrice, zone.multiplier);
                option.suggested = r[0] == REPLACEMENT_BETTER;
                result.options.add(option);
            }
            if (result.options.isEmpty()) {
                throw new VisitException('The replacement systems are not in the price book.');
            }
            return result;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Places a replacement quote for the chosen system and links it to the system check. */
    @AuraEnabled
    public static QuoteResult createReplacementQuote(Id recordId, String sku) {
        try {
            if (!new Set<String>{ REPLACEMENT_GOOD, REPLACEMENT_BETTER, REPLACEMENT_BEST }.contains(sku)) {
                throw new VisitException('Choose a replacement option.');
            }
            WorkOrder wo = workOrderFor(recordId);
            if (wo.RLM_HVAC_Assessment__c == null) {
                throw new VisitException('Check the system before quoting a replacement.');
            }
            RLM_HVAC_Assessment__c assessment = [
                SELECT Replacement_Quote__c, System_Type__c FROM RLM_HVAC_Assessment__c WHERE Id = :wo.RLM_HVAC_Assessment__c
            ];
            if (assessment.Replacement_Quote__c != null) {
                return quoteResult(assessment.Replacement_Quote__c, 'Replacement quote already created for this system check.');
            }
            RLM_HVAC_FieldQuote.Request request = new RLM_HVAC_FieldQuote.Request();
            request.accountId = wo.AccountId;
            request.replacementSku = sku;
            request.systemType = assessment.System_Type__c;
            request.opportunityName = wo.Account.Name + ' - System Replacement';
            RLM_HVAC_FieldQuote.Response response = RLM_HVAC_FieldQuote.createQuote(request);
            if (response.success != true) {
                throw new VisitException(response.message);
            }
            update new RLM_HVAC_Assessment__c(
                Id = wo.RLM_HVAC_Assessment__c, Replacement_Quote__c = response.quoteId, Replacement_Sku__c = sku
            );
            update new Quote(Id = response.quoteId,
                RLM_HVAC_Plan_Explanation__c = replacementReason(wo.RLM_HVAC_Assessment__c, sku).abbreviate(2000));
            QuoteResult result = quoteResult(response.quoteId, response.message);
            result.zoneCode = response.zoneCode;
            result.zoneMultiplier = response.zoneMultiplier;
            return result;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Why the replacement: the equipment age, what needs work, and what the chosen system changes. */
    @TestVisible
    private static String replacementReason(Id assessmentId, String sku) {
        RLM_HVAC_Assessment.AssessmentState state = RLM_HVAC_Assessment.getState(assessmentId);
        List<String> parts = new List<String>();
        Integer oldest = state.recommendation?.oldestAge;
        if (oldest != null) {
            parts.add('Your oldest equipment is ' + oldest + ' years old'
                + (oldest >= RLM_HVAC_Assessment.REPLACEMENT_AGE ? ', near the end of its life.' : '.'));
        }
        List<String> problems = new List<String>();
        for (RLM_HVAC_Finding__c f : [
            SELECT Equipment__c, Component__c, Condition__c, Urgency__c, Reading__c FROM RLM_HVAC_Finding__c
            WHERE Assessment__c = :assessmentId AND Urgency__c IN ('Safety', 'Repair Soon')
            ORDER BY Urgency__c DESC, CreatedDate
        ]) {
            problems.add(RLM_HVAC_Assessment.describe(f));
        }
        if (!problems.isEmpty()) {
            parts.add('We found: ' + String.join(problems, '; ') + '.');
        }
        for (List<String> r : REPLACEMENTS) {
            if (r[0] == sku) {
                parts.add('Rather than repair it, we recommend replacing it. You chose the ' + r[1].toLowerCase()
                    + ' option, a ' + r[2].uncapitalize() + ' (' + r[3].split('\\|')[0] + ').');
            }
        }
        return String.join(parts, ' ');
    }

    private static Map<String, PricebookEntry> replacementEntries() {
        Set<String> skus = new Set<String>{
            REPLACEMENT_GOOD + skuSuffix, REPLACEMENT_BETTER + skuSuffix, REPLACEMENT_BEST + skuSuffix
        };
        Id standardPricebookId = Test.isRunningTest() ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        Map<String, PricebookEntry> entries = new Map<String, PricebookEntry>();
        for (PricebookEntry entry : [
            SELECT UnitPrice, Product2.Name, Product2.StockKeepingUnit FROM PricebookEntry
            WHERE Product2.StockKeepingUnit IN :skus AND Pricebook2Id = :standardPricebookId
                AND CurrencyIsoCode = 'USD' AND IsActive = true
        ]) {
            entries.put(entry.Product2.StockKeepingUnit.removeEnd(skuSuffix), entry);
        }
        return entries;
    }

    /** Starts proposal generation, or returns the proposal already on the quote. */
    @AuraEnabled
    public static ProposalStatus startProposal(Id quoteId) {
        try {
            RLM_SignAndPay.ProposalDoc existing = RLM_SignAndPay.findLatestProposal(quoteId);
            if (existing != null && existing.title != null && existing.title.startsWith(proposalTitle(quoteId))) {
                ProposalStatus ready = new ProposalStatus();
                ready.status = 'Ready';
                ready.contentDocumentId = existing.contentDocumentId;
                ready.title = existing.title;
                return ready;
            }
            String templateName = isReplacementQuote(quoteId) ? REPLACEMENT_PROPOSAL_TEMPLATE : PROPOSAL_TEMPLATE;
            List<DocumentTemplate> templates = [
                SELECT Id FROM DocumentTemplate
                WHERE Name = :templateName AND IsActive = true
                ORDER BY VersionNumber DESC LIMIT 1
            ];
            if (templates.isEmpty()) {
                throw new VisitException('The Brightline proposal template is not active in this org.');
            }
            DocumentGenerationProcess process = new DocumentGenerationProcess(
                Type = 'GenerateAndConvert',
                ReferenceObject = quoteId,
                DocumentTemplateId = templates[0].Id,
                RequestText = JSON.serialize(new Map<String, Object>{
                    'keepIntermediate' => false,
                    'title' => proposalTitle(quoteId)
                }),
                DocGenApiVersionType = 'Advanced',
                DocumentInputType = 'DocumentTemplate',
                DataRaptorInput = JSON.serialize(new Map<String, Object>{ 'Id' => quoteId })
            );
            insert process;
            ProposalStatus status = new ProposalStatus();
            status.processId = process.Id;
            status.status = 'Generating';
            return status;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Checks a generation request; once done, makes sure the PDF is attached to the quote. */
    @AuraEnabled
    public static ProposalStatus proposalStatus(Id processId, Id quoteId) {
        try {
            DocumentGenerationProcess process = [
                SELECT Id, Status, ResponseText FROM DocumentGenerationProcess WHERE Id = :processId
            ];
            ProposalStatus status = new ProposalStatus();
            status.processId = process.Id;
            if (process.Status == 'Failure') {
                status.status = 'Failed';
                status.message = String.isBlank(process.ResponseText) ? 'Proposal generation failed.' : process.ResponseText;
                return status;
            }
            if (process.Status != 'Success') {
                status.status = 'Generating';
                return status;
            }
            List<Id> versionIds = new List<Id>();
            for (String token : (process.ResponseText == null ? '' : process.ResponseText).split(',')) {
                try {
                    versionIds.add(Id.valueOf(token.trim()));
                } catch (Exception notAnId) {
                    continue;
                }
            }
            List<ContentVersion> pdfs = [
                SELECT ContentDocumentId, Title FROM ContentVersion
                WHERE Id IN :versionIds AND FileType = 'PDF' LIMIT 1
            ];
            if (pdfs.isEmpty()) {
                status.status = 'Failed';
                status.message = 'The proposal finished without a PDF.';
                return status;
            }
            if ([SELECT COUNT() FROM ContentDocumentLink
                 WHERE LinkedEntityId = :quoteId AND ContentDocumentId = :pdfs[0].ContentDocumentId] == 0) {
                insert new ContentDocumentLink(
                    LinkedEntityId = quoteId,
                    ContentDocumentId = pdfs[0].ContentDocumentId,
                    ShareType = 'V'
                );
            }
            status.status = 'Ready';
            status.contentDocumentId = pdfs[0].ContentDocumentId;
            status.title = pdfs[0].Title;
            return status;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Creates the order from the signed quote. Activation happens in orderStatus once the order exists. */
    @AuraEnabled
    public static OrderStatus placeOrder(Id quoteId) {
        try {
            Quote q = [SELECT Id, RLM_Demo_Signed_At__c FROM Quote WHERE Id = :quoteId];
            if (q.RLM_Demo_Signed_At__c == null) {
                throw new VisitException('The customer has not signed this quote yet.');
            }
            if (ordersFor(quoteId).isEmpty()) {
                // createOrderFromQuote is not invocable from Apex; createOrdersFromQuote is, with a String id.
                Invocable.Action action = Invocable.Action.createStandardAction('createOrdersFromQuote');
                action.setInvocationParameter('quoteId', String.valueOf(quoteId));
                Invocable.Action.Result result = action.invoke()[0];
                if (!result.isSuccess()) {
                    List<String> errors = new List<String>();
                    for (Invocable.Action.Error error : result.getErrors()) {
                        errors.add(error.getMessage());
                    }
                    throw new VisitException('Could not create the order: ' + String.join(errors, '; '));
                }
            }
            return orderStatus(quoteId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Reports the order for a quote. Activates it once it exists in Draft, which starts fulfillment;
     * fulfillment then creates the Initial Tune-up work order.
     */
    @AuraEnabled
    public static OrderStatus orderStatus(Id quoteId) {
        try {
            OrderStatus status = new OrderStatus();
            List<Order> orders = ordersFor(quoteId);
            if (orders.isEmpty()) {
                status.status = 'Creating';
                return status;
            }
            Order o = orders[0];
            status.orderId = o.Id;
            status.orderNumber = o.OrderNumber;
            status.status = o.Status;
            if (o.Status == 'Draft') {
                // Activation rejects orders without a bill-to contact.
                Id contactId = o.BillToContactId != null ? o.BillToContactId : customerContact(o);
                if (contactId == null) {
                    throw new VisitException('Add a contact to ' + o.Account.Name + ' before booking the tune-up.');
                }
                update new Order(
                    Id = o.Id,
                    BillToContactId = contactId,
                    ShipToContactId = o.ShipToContactId != null ? o.ShipToContactId : contactId,
                    Status = 'Activated'
                );
                status.status = 'Activated';
                markAccepted(quoteId);
            }
            List<WorkOrder> tuneUps = [
                SELECT Id, WorkOrderNumber,
                    (SELECT Id, SchedStartTime FROM ServiceAppointments ORDER BY SchedStartTime ASC NULLS LAST LIMIT 1)
                FROM WorkOrder WHERE RLM_Order__c = :o.Id ORDER BY CreatedDate ASC LIMIT 1
            ];
            if (!tuneUps.isEmpty()) {
                status.tuneUpWorkOrderId = tuneUps[0].Id;
                status.tuneUpWorkOrderNumber = tuneUps[0].WorkOrderNumber;
                if (!tuneUps[0].ServiceAppointments.isEmpty()) {
                    status.tuneUpAppointmentId = tuneUps[0].ServiceAppointments[0].Id;
                    status.tuneUpScheduledStart = tuneUps[0].ServiceAppointments[0].SchedStartTime;
                }
            }
            return status;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Open times for the Initial Tune-up, Monday to Saturday inside the appointment's window, that
     * don't overlap the running technician's other appointments.
     */
    @AuraEnabled
    public static List<Slot> tuneUpSlots(Id appointmentId) {
        try {
            ServiceAppointment sa = tuneUpAppointment(appointmentId);
            Integer minutes = durationMinutes(sa);
            ServiceResource resource = technician();
            TimeZone zone = sa.ServiceTerritory.OperatingHours.TimeZone == null
                ? UserInfo.getTimeZone() : TimeZone.getTimeZone(sa.ServiceTerritory.OperatingHours.TimeZone);
            Datetime windowStart = sa.EarliestStartTime == null || sa.EarliestStartTime < Datetime.now()
                ? Datetime.now() : sa.EarliestStartTime;
            Datetime windowEnd = sa.DueDate == null ? windowStart.addDays(SLOT_DAYS) : sa.DueDate;

            List<ServiceAppointment> busy = [
                SELECT SchedStartTime, SchedEndTime FROM ServiceAppointment
                WHERE Id IN (SELECT ServiceAppointmentId FROM AssignedResource WHERE ServiceResourceId = :resource.Id)
                    AND SchedStartTime < :windowEnd AND SchedEndTime > :windowStart
                    AND Status NOT IN ('Canceled', 'Cannot Complete')
            ];

            List<Slot> slots = new List<Slot>();
            Date tomorrow = Date.today().addDays(1);
            Date day = windowStart.date() > tomorrow ? windowStart.date() : tomorrow;
            Date knownSunday = Date.newInstance(1900, 1, 7);
            while (slots.size() < SLOT_COUNT && day <= windowEnd.date()) {
                Integer weekday = Math.mod(knownSunday.daysBetween(day), 7);
                if (weekday != 0) {
                    for (Integer hour : SLOT_HOURS) {
                        Datetime startTime = zonedStart(day, hour, zone);
                        Datetime endTime = startTime.addMinutes(minutes);
                        if (startTime < windowStart || endTime > windowEnd || overlaps(busy, startTime, endTime)) {
                            continue;
                        }
                        Slot slot = new Slot();
                        slot.startTime = startTime;
                        slot.endTime = endTime;
                        slots.add(slot);
                        if (slots.size() == SLOT_COUNT) {
                            break;
                        }
                    }
                }
                day = day.addDays(1);
            }
            return slots;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Schedules the Initial Tune-up at the chosen time and dispatches it to the running technician. */
    @AuraEnabled
    public static OrderStatus bookTuneUp(Id appointmentId, Datetime startTime, Id quoteId) {
        try {
            ServiceAppointment sa = tuneUpAppointment(appointmentId);
            if (startTime == null || startTime < Datetime.now()) {
                throw new VisitException('Pick a time in the future.');
            }
            ServiceResource resource = technician();
            Datetime endTime = startTime.addMinutes(durationMinutes(sa));
            sa.SchedStartTime = startTime;
            sa.SchedEndTime = endTime;
            sa.ArrivalWindowStartTime = startTime;
            sa.ArrivalWindowEndTime = startTime.addHours(1);
            sa.Status = 'Dispatched';
            update sa;
            if ([SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id] == 0) {
                insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = resource.Id);
            }
            return orderStatus(quoteId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Completes the visit from the app, which has no status picker in this org: every open
     * appointment on the work order, then the work order. Completing the Initial Tune-up work order
     * starts milestone billing (RLM_FSL_Complete_Fulfillment_Step).
     */
    @AuraEnabled
    public static String completeVisit(Id recordId) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            List<ServiceAppointment> open = [
                SELECT Id, ActualStartTime FROM ServiceAppointment
                WHERE ParentRecordId = :wo.Id AND Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
            ];
            Datetime now = Datetime.now();
            Datetime startedAt = wo.StartDate;
            for (ServiceAppointment sa : open) {
                sa.Status = 'Completed';
                sa.ActualEndTime = now;
                if (sa.ActualStartTime == null) {
                    sa.ActualStartTime = now;
                }
                sa.ActualDuration = Math.max(1, (now.getTime() - sa.ActualStartTime.getTime()) / 60000);
                if (startedAt == null || sa.ActualStartTime < startedAt) {
                    startedAt = sa.ActualStartTime;
                }
            }
            update open;
            List<WorkOrderLineItem> addOns = [
                SELECT Id FROM WorkOrderLineItem
                WHERE WorkOrderId = :wo.Id AND RLM_HVAC_Approved_At__c != null AND Status != 'Completed'
            ];
            for (WorkOrderLineItem line : addOns) {
                line.Status = 'Completed';
            }
            update addOns;
            update new WorkOrder(Id = wo.Id, Status = 'Completed', StartDate = startedAt ?? now, EndDate = now);
            return wo.WorkOrderNumber;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static final Integer SLOT_COUNT = 6;
    private static final Integer SLOT_DAYS = 7;
    private static final List<Integer> SLOT_HOURS = new List<Integer>{ 8, 10, 13, 15 };

    private static ServiceAppointment tuneUpAppointment(Id appointmentId) {
        List<ServiceAppointment> appointments = [
            SELECT Id, Status, EarliestStartTime, DueDate, Duration, DurationType,
                ServiceTerritory.OperatingHours.TimeZone
            FROM ServiceAppointment WHERE Id = :appointmentId
        ];
        if (appointments.isEmpty()) {
            throw new VisitException('The tune-up appointment was not found.');
        }
        return appointments[0];
    }

    private static ServiceResource technician() {
        List<ServiceResource> resources = [
            SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
        ];
        if (resources.isEmpty()) {
            throw new VisitException('You are not set up as a service resource, so the visit is left for dispatch.');
        }
        return resources[0];
    }

    private static Integer durationMinutes(ServiceAppointment sa) {
        if (sa.Duration == null || sa.Duration <= 0) {
            return 60;
        }
        return (Integer) (sa.DurationType == 'Minutes' ? sa.Duration : sa.Duration * 60);
    }

    /** The instant when the clock reads day at hour:00 in zone. */
    private static Datetime zonedStart(Date day, Integer hour, TimeZone zone) {
        Datetime wall = Datetime.newInstanceGmt(day, Time.newInstance(hour, 0, 0, 0));
        Datetime guess = wall.addSeconds(-zone.getOffset(wall) / 1000);
        return wall.addSeconds(-zone.getOffset(guess) / 1000);
    }

    private static Boolean overlaps(List<ServiceAppointment> busy, Datetime startTime, Datetime endTime) {
        for (ServiceAppointment b : busy) {
            if (b.SchedStartTime < endTime && b.SchedEndTime > startTime) {
                return true;
            }
        }
        return false;
    }

    private static void markAccepted(Id quoteId) {
        List<RLM_HVAC_Assessment__c> assessments = [
            SELECT Id FROM RLM_HVAC_Assessment__c WHERE Quote__c = :quoteId AND Status__c != 'Accepted'
        ];
        for (RLM_HVAC_Assessment__c assessment : assessments) {
            assessment.Status__c = 'Accepted';
        }
        update assessments;
    }

    private static WorkOrder workOrderFor(Id recordId) {
        if (recordId == null) {
            throw new VisitException('Open this action from a service appointment or work order.');
        }
        Id workOrderId = recordId;
        if (recordId.getSobjectType() == ServiceAppointment.SObjectType) {
            ServiceAppointment sa = [SELECT ParentRecordId FROM ServiceAppointment WHERE Id = :recordId];
            if (sa.ParentRecordId == null || sa.ParentRecordId.getSobjectType() != WorkOrder.SObjectType) {
                throw new VisitException('This appointment is not attached to a work order.');
            }
            workOrderId = sa.ParentRecordId;
        } else if (recordId.getSobjectType() != WorkOrder.SObjectType) {
            throw new VisitException('Open this action from a service appointment or work order.');
        }
        return [
            SELECT Id, WorkOrderNumber, AccountId, Account.Name, Account.ShippingStreet, Account.ShippingCity,
                Account.ShippingState, Account.ShippingPostalCode, Street, City, State, PostalCode,
                RLM_Order__c, RLM_HVAC_Assessment__c, RLM_HVAC_Assessment__r.Quote__c, StatusCategory, StartDate
            FROM WorkOrder WHERE Id = :workOrderId
        ];
    }

    private static List<Order> ordersFor(Id quoteId) {
        return [
            SELECT Id, OrderNumber, Status, AccountId, Account.Name, BillToContactId, ShipToContactId,
                Quote.BillToContactId, Quote.ContactId
            FROM Order WHERE QuoteId = :quoteId ORDER BY CreatedDate DESC LIMIT 1
        ];
    }

    private static Id customerContact(Order o) {
        if (o.Quote.BillToContactId != null) {
            return o.Quote.BillToContactId;
        }
        if (o.Quote.ContactId != null) {
            return o.Quote.ContactId;
        }
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :o.AccountId ORDER BY CreatedDate ASC LIMIT 1];
        return contacts.isEmpty() ? null : contacts[0].Id;
    }

    private static QuoteResult quoteResult(Id quoteId, String message) {
        QuoteResult result = new QuoteResult();
        result.quoteId = quoteId;
        result.quoteNumber = [SELECT QuoteNumber FROM Quote WHERE Id = :quoteId].QuoteNumber;
        result.message = message;
        return result;
    }

    private static String proposalTitle(Id quoteId) {
        return (isReplacementQuote(quoteId) ? 'Brightline Replacement Proposal ' : 'Brightline Proposal ')
            + [SELECT QuoteNumber FROM Quote WHERE Id = :quoteId].QuoteNumber;
    }

    private static Boolean isReplacementQuote(Id quoteId) {
        return [SELECT COUNT() FROM RLM_HVAC_Assessment__c WHERE Replacement_Quote__c = :quoteId] > 0;
    }

    private static String joinAddress(String street, String city, String state, String postalCode) {
        List<String> parts = new List<String>();
        for (String part : new List<String>{ street, city, String.join(new List<String>{
                state == null ? '' : state, postalCode == null ? '' : postalCode }, ' ').trim() }) {
            if (String.isNotBlank(part)) {
                parts.add(part);
            }
        }
        return String.join(parts, ', ');
    }

    private class VisitException extends Exception {}

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }
}
