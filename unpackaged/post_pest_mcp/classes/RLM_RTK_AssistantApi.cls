/**
 * REST facade for the Verdant Field Assistant MCP server: POST /services/apexrest/verdant/assistant
 * with {"operation": "...", "params": {...}}. Each operation calls the same Apex the Field Service
 * screens use, so pricing, coverage, scheduling and billing rules stay in Salesforce. Responses are
 * {"success": true, "result": ...} or {"success": false, "error": "..."} with status 200, so the
 * assistant can explain a refusal instead of failing the call.
 */
@RestResource(urlMapping='/verdant/assistant/*')
global with sharing class RLM_RTK_AssistantApi {

    @HttpPost
    global static void handle() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        Map<String, Object> out = new Map<String, Object>();
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.request.requestBody.toString());
            Object params = body.get('params');
            out.put('result', run((String) body.get('operation'),
                params == null ? new Map<String, Object>() : (Map<String, Object>) params));
            out.put('success', true);
        } catch (Exception e) {
            out.put('success', false);
            out.put('error', e.getMessage());
        }
        response.statusCode = 200;
        response.responseBody = Blob.valueOf(JSON.serialize(out, true));
    }

    /** Runs one operation; params are the JSON object the MCP tool sent. */
    public static Object run(String operation, Map<String, Object> values) {
        Params p = new Params(values);
        switch on operation {
            when 'bookInspection' {
                RLM_RTK_Assistant.Caller caller = new RLM_RTK_Assistant.Caller();
                caller.name = p.required('name');
                caller.street = p.required('street');
                caller.city = p.text('city');
                caller.state = p.text('state');
                caller.postalCode = p.text('postalCode');
                caller.phone = p.text('phone');
                caller.email = p.text('email');
                caller.description = p.text('description');
                return RLM_RTK_Assistant.bookInspection(caller, p.dateValue('day'), p.integerValue('hour'));
            }
            when 'bookReservice' {
                return RLM_RTK_Assistant.bookReservice(p.id('accountId'), p.required('pest'), p.text('description'),
                    p.dateValue('day'), p.integerValue('hour'));
            }
            when 'schedule' {
                Date day = p.dateValue('day');
                return RLM_RTK_Assistant.schedule(day == null ? Date.today() : day);
            }
            when 'findCustomers' {
                return RLM_RTK_Assistant.findCustomers(p.required('search'));
            }
            when 'customerSummary' {
                return RLM_RTK_Assistant.customerSummary(p.id('accountId'));
            }
            when 'visitBrief' {
                return RLM_RTK_AI.getBrief(p.id('recordId'), p.bool('regenerate'));
            }
            when 'visitContext' {
                Id recordId = p.id('recordId');
                return new Map<String, Object>{
                    'context' => RLM_RTK_FieldVisit.getContext(recordId),
                    'timing' => RLM_RTK_FieldVisit.getVisitTiming(recordId)
                };
            }
            when 'startVisit' {
                Id recordId = p.id('recordId');
                RLM_RTK_FieldVisit.VisitContext context = RLM_RTK_FieldVisit.getContext(recordId);
                Map<String, Object> started = new Map<String, Object>();
                if (context.canInspect == true) {
                    started.put('inspectionId', RLM_RTK_FieldVisit.startInspection(context.workOrderId));
                } else {
                    RLM_RTK_FieldVisit.startVisit(recordId);
                }
                started.put('context', RLM_RTK_FieldVisit.getContext(recordId));
                started.put('timing', RLM_RTK_FieldVisit.getVisitTiming(recordId));
                return started;
            }
            when 'recordFinding' {
                RLM_RTK_Inspection.FindingInput finding = new RLM_RTK_Inspection.FindingInput();
                finding.id = p.optionalId('findingId');
                finding.zone = p.required('zone');
                finding.pest = p.text('pest');
                finding.evidence = p.text('evidence');
                finding.severity = p.text('severity');
                finding.customerNote = p.text('customerNote');
                finding.internalNote = p.text('internalNote');
                return RLM_RTK_Inspection.saveFinding(inspectionFor(p), finding);
            }
            when 'attachPhoto' {
                String stage = p.text('stage');
                Id documentId = RLM_RTK_Inspection.uploadPhoto(p.id('findingId'), p.required('fileName'),
                    p.required('base64Data'), String.isBlank(stage) ? 'Before' : stage);
                return new Map<String, Object>{ 'contentDocumentId' => documentId };
            }
            when 'inspection' {
                Id inspectionId = p.optionalId('inspectionId');
                return inspectionId != null
                    ? RLM_RTK_Inspection.getState(inspectionId)
                    : RLM_RTK_Inspection.getWorkOrderFindings(workOrderOf(p));
            }
            when 'pricing' {
                return RLM_RTK_FieldQuote.pricingFor(p.required('postalCode'));
            }
            when 'createQuote' {
                String propertyType = p.text('propertyType');
                RLM_RTK_FieldVisit.QuoteResult created = RLM_RTK_FieldVisit.createQuote(workOrderOf(p), p.required('planSku'),
                    String.isBlank(propertyType) ? 'SingleFamily' : propertyType, p.required('squareFootage'), p.required('severity'),
                    p.bool('includeMosquito'), p.bool('includeTermite'), p.text('overrideReason'));
                return new Map<String, Object>{
                    'created' => created,
                    'quote' => RLM_RTK_Assistant.quoteDetails(created.quoteId)
                };
            }
            when 'quote' {
                return RLM_RTK_Assistant.quoteDetails(p.id('quoteId'));
            }
            when 'startProposal' {
                return RLM_RTK_FieldVisit.startProposal(p.id('quoteId'));
            }
            when 'proposalStatus' {
                return RLM_RTK_FieldVisit.proposalStatus(p.id('processId'), p.id('quoteId'));
            }
            when 'acceptQuote' {
                Id quoteId = p.id('quoteId');
                p.required('approvalStatement');
                RLM_SignAndPay.ProposalDoc proposal = RLM_SignAndPay.findLatestProposal(quoteId);
                if (proposal == null || proposal.contentDocumentId == null) {
                    throw new AssistantApiException('Generate the proposal and show it to the customer before they sign.');
                }
                String brand = p.text('cardBrand');
                RLM_SignAndPay.AcceptResponse accepted = RLM_SignAndPay.accept(quoteId, proposal.contentDocumentId,
                    p.required('signerName'), p.text('cardLast4'), String.isBlank(brand) ? 'Card' : brand);
                if (accepted.success != true) {
                    throw new AssistantApiException(accepted.message);
                }
                return RLM_RTK_Assistant.quoteDetails(quoteId);
            }
            when 'placeOrder' {
                return RLM_RTK_FieldVisit.placeOrder(p.id('quoteId'));
            }
            when 'orderStatus' {
                return RLM_RTK_FieldVisit.orderStatus(p.id('quoteId'));
            }
            when 'treatmentSlots' {
                return RLM_RTK_FieldVisit.treatmentSlots(p.id('appointmentId'));
            }
            when 'bookTreatment' {
                Id appointmentId = p.id('appointmentId');
                ServiceAppointment sa = [SELECT ParentRecordId FROM ServiceAppointment WHERE Id = :appointmentId];
                WorkOrder wo = [SELECT RLM_Order__r.QuoteId FROM WorkOrder WHERE Id = :sa.ParentRecordId];
                return RLM_RTK_FieldVisit.bookTreatment(appointmentId, p.datetimeValue('startTime'), wo.RLM_Order__r?.QuoteId);
            }
            when 'recordTreatment' {
                return RLM_RTK_Inspection.saveTreatment(workOrderOf(p), p.id('findingId'), p.required('status'), p.text('note'));
            }
            when 'addOnOptions' {
                return RLM_RTK_FieldAddOn.getState(p.id('recordId'));
            }
            when 'addAddOns' {
                return RLM_RTK_FieldAddOn.addAddOns(p.id('recordId'), p.strings('skus'), p.required('approvedBy'));
            }
            when 'planOptions' {
                return RLM_RTK_PlanChange.getState(p.id('recordId'));
            }
            when 'changePlan' {
                return RLM_RTK_PlanChange.applyChange(p.id('recordId'), p.required('sku'), p.required('approvedBy'));
            }
            when 'completeVisit' {
                Id recordId = p.id('recordId');
                return new Map<String, Object>{
                    'workOrderNumber' => RLM_RTK_FieldVisit.completeVisit(recordId),
                    'timing' => RLM_RTK_FieldVisit.getVisitTiming(recordId)
                };
            }
            when 'visitSummary' {
                return RLM_RTK_AI.summarizeVisit(p.id('recordId'));
            }
            when 'explainBill' {
                RLM_RTK_BillExplainer.Request request = new RLM_RTK_BillExplainer.Request();
                request.accountId = p.optionalId('accountId');
                request.accountName = p.text('accountName');
                request.invoiceNumber = p.text('invoiceNumber');
                request.amount = p.decimalValue('amount');
                return RLM_RTK_BillExplainer.explain(new List<RLM_RTK_BillExplainer.Request>{ request })[0];
            }
            when 'resetDemo' {
                return RLM_RTK_DemoReset.reset(p.required('customerName'));
            }
            when else {
                throw new AssistantApiException('Unknown operation ' + operation + '.');
            }
        }
    }

    /** The inspection a finding belongs to: given directly, or the one linked to the visit's work order. */
    private static Id inspectionFor(Params p) {
        Id inspectionId = p.optionalId('inspectionId');
        if (inspectionId != null) {
            return inspectionId;
        }
        Id workOrderId = workOrderOf(p);
        WorkOrder wo = [SELECT RLM_RTK_Inspection__c FROM WorkOrder WHERE Id = :workOrderId];
        if (wo.RLM_RTK_Inspection__c == null) {
            throw new AssistantApiException('This visit has no inspection yet. Start the visit first.');
        }
        return wo.RLM_RTK_Inspection__c;
    }

    /** The work order a visit param names; an appointment Id resolves to its work order. */
    private static Id workOrderOf(Params p) {
        Id recordId = p.optionalId('workOrderId') ?? p.id('recordId');
        if (recordId.getSObjectType() == ServiceAppointment.SObjectType) {
            return [SELECT ParentRecordId FROM ServiceAppointment WHERE Id = :recordId].ParentRecordId;
        }
        return recordId;
    }

    public class Params {
        private final Map<String, Object> values;

        public Params(Map<String, Object> values) {
            this.values = values;
        }

        public String text(String key) {
            Object value = values.get(key);
            return value == null ? null : String.valueOf(value);
        }

        public String required(String key) {
            String value = text(key);
            if (String.isBlank(value)) {
                throw new AssistantApiException('Missing ' + key + '.');
            }
            return value.trim();
        }

        public Id id(String key) {
            return Id.valueOf(required(key));
        }

        public Id optionalId(String key) {
            String value = text(key);
            return String.isBlank(value) ? null : Id.valueOf(value.trim());
        }

        public Boolean bool(String key) {
            Object value = values.get(key);
            return value instanceof Boolean ? (Boolean) value : 'true'.equalsIgnoreCase(text(key));
        }

        public Integer integerValue(String key) {
            String value = text(key);
            return String.isBlank(value) ? null : Decimal.valueOf(value).intValue();
        }

        public Decimal decimalValue(String key) {
            String value = text(key);
            return String.isBlank(value) ? null : Decimal.valueOf(value.remove('$').remove(','));
        }

        public Date dateValue(String key) {
            String value = text(key);
            return String.isBlank(value) ? null : Date.valueOf(value.trim().left(10));
        }

        public Datetime datetimeValue(String key) {
            return (Datetime) JSON.deserialize('"' + required(key) + '"', Datetime.class);
        }

        public List<String> strings(String key) {
            List<String> result = new List<String>();
            Object value = values.get(key);
            if (value instanceof List<Object>) {
                for (Object item : (List<Object>) value) {
                    result.add(String.valueOf(item));
                }
            } else if (value != null) {
                for (String item : String.valueOf(value).split(',')) {
                    if (String.isNotBlank(item)) {
                        result.add(item.trim());
                    }
                }
            }
            return result;
        }
    }

    public class AssistantApiException extends Exception {}
}
