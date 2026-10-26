/**
 * Server side of the Inspect & Quote quick action that runs from a Service Appointment or
 * Work Order in the Field Service mobile app: start the inspection, create the quote,
 * generate the proposal, then turn the signed quote into an activated order so fulfillment
 * creates the treatment work order. Each step is safe to call again when the technician
 * reopens the action.
 */
public with sharing class RLM_RTK_FieldVisit {
    public static final String PROPOSAL_TEMPLATE = 'RLM_RTK_PestProposal';

    public class VisitContext {
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public Boolean canInspect;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String serviceAddress;
        @AuraEnabled public String postalCode;
        @AuraEnabled public Id inspectionId;
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
        @AuraEnabled public Id treatmentWorkOrderId;
        @AuraEnabled public String treatmentWorkOrderNumber;
        @AuraEnabled public Datetime treatmentScheduledStart;
    }

    @AuraEnabled
    public static VisitContext getContext(Id recordId) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            VisitContext ctx = new VisitContext();
            ctx.workOrderId = wo.Id;
            ctx.workOrderNumber = wo.WorkOrderNumber;
            ctx.canInspect = wo.RLM_Order__c == null && wo.AccountId != null;
            ctx.accountId = wo.AccountId;
            ctx.accountName = wo.Account?.Name;
            ctx.postalCode = String.isNotBlank(wo.PostalCode) ? wo.PostalCode : wo.Account?.ShippingPostalCode;
            ctx.serviceAddress = String.isNotBlank(wo.Street)
                ? joinAddress(wo.Street, wo.City, wo.State, wo.PostalCode)
                : joinAddress(wo.Account?.ShippingStreet, wo.Account?.ShippingCity, wo.Account?.ShippingState,
                    wo.Account?.ShippingPostalCode);
            ctx.inspectionId = wo.RLM_RTK_Inspection__c;
            ctx.stage = 'start';
            if (ctx.inspectionId == null) {
                return ctx;
            }
            ctx.stage = 'walk';
            ctx.quoteId = wo.RLM_RTK_Inspection__r.Quote__c;
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

    /** Creates the inspection for this visit and links it to the work order, or returns the existing one. */
    @AuraEnabled
    public static Id startInspection(Id workOrderId) {
        try {
            WorkOrder wo = workOrderFor(workOrderId);
            if (wo.RLM_RTK_Inspection__c != null) {
                return wo.RLM_RTK_Inspection__c;
            }
            if (wo.RLM_Order__c != null || wo.AccountId == null) {
                throw new VisitException('Inspect & Quote runs from an inspection visit, not a treatment work order.');
            }
            RLM_RTK_Inspection__c inspection = new RLM_RTK_Inspection__c(
                Account__c = wo.AccountId,
                Status__c = 'In Progress'
            );
            insert inspection;
            update new WorkOrder(Id = wo.Id, RLM_RTK_Inspection__c = inspection.Id);
            return inspection.Id;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static QuoteResult createQuote(
        Id workOrderId,
        String planSku,
        String propertyType,
        String squareFootage,
        String severity,
        Boolean includeMosquito,
        Boolean includeTermite,
        String overrideReason
    ) {
        try {
            WorkOrder wo = workOrderFor(workOrderId);
            if (wo.RLM_RTK_Inspection__c == null) {
                throw new VisitException('Walk the property before creating the quote.');
            }
            if (wo.RLM_RTK_Inspection__r.Quote__c != null) {
                return quoteResult(wo.RLM_RTK_Inspection__r.Quote__c, 'Quote already created for this inspection.');
            }
            RLM_RTK_FieldQuote.Request request = new RLM_RTK_FieldQuote.Request();
            request.accountId = wo.AccountId;
            request.planSku = planSku;
            request.propertyType = propertyType;
            request.squareFootage = squareFootage;
            request.severity = severity;
            request.includeMosquito = includeMosquito;
            request.includeTermite = includeTermite;
            request.inspectionId = wo.RLM_RTK_Inspection__c;
            request.overrideReason = overrideReason;
            RLM_RTK_FieldQuote.Response response = RLM_RTK_FieldQuote.createQuote(request);
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
            List<DocumentTemplate> templates = [
                SELECT Id FROM DocumentTemplate
                WHERE Name = :PROPOSAL_TEMPLATE AND IsActive = true
                ORDER BY VersionNumber DESC LIMIT 1
            ];
            if (templates.isEmpty()) {
                throw new VisitException('The Rentokil proposal template is not active in this org.');
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
     * fulfillment then creates the treatment work order.
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
                    throw new VisitException('Add a contact to ' + o.Account.Name + ' before booking the treatment.');
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
            List<WorkOrder> treatments = [
                SELECT Id, WorkOrderNumber,
                    (SELECT SchedStartTime FROM ServiceAppointments ORDER BY SchedStartTime ASC NULLS LAST LIMIT 1)
                FROM WorkOrder WHERE RLM_Order__c = :o.Id ORDER BY CreatedDate ASC LIMIT 1
            ];
            if (!treatments.isEmpty()) {
                status.treatmentWorkOrderId = treatments[0].Id;
                status.treatmentWorkOrderNumber = treatments[0].WorkOrderNumber;
                if (!treatments[0].ServiceAppointments.isEmpty()) {
                    status.treatmentScheduledStart = treatments[0].ServiceAppointments[0].SchedStartTime;
                }
            }
            return status;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static void markAccepted(Id quoteId) {
        List<RLM_RTK_Inspection__c> inspections = [
            SELECT Id FROM RLM_RTK_Inspection__c WHERE Quote__c = :quoteId AND Status__c != 'Accepted'
        ];
        for (RLM_RTK_Inspection__c inspection : inspections) {
            inspection.Status__c = 'Accepted';
        }
        update inspections;
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
                RLM_Order__c, RLM_RTK_Inspection__c, RLM_RTK_Inspection__r.Quote__c
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
        return 'Rentokil Proposal ' + [SELECT QuoteNumber FROM Quote WHERE Id = :quoteId].QuoteNumber;
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
