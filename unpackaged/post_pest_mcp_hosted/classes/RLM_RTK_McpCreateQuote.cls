/** Verdant hosted MCP tool create_quote. */
public with sharing class RLM_RTK_McpCreateQuote {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
        @InvocableVariable(label='Plan SKU' description='One of: RTK-ESSENTIAL, RTK-HOME-PROT, RTK-HOME-PROT-PLUS.' required=true)
        public String planSku;
        @InvocableVariable(label='Square Footage' description='One of: Under2000, 2000to3500, Over3500.' required=true)
        public String squareFootage;
        @InvocableVariable(label='Severity' description='One of: Light, Moderate, Heavy.' required=true)
        public String severity;
        @InvocableVariable(label='Include Mosquito' description='True to add the Mosquito plan.')
        public Boolean includeMosquito;
        @InvocableVariable(label='Include Termite' description='True to add the Termite plan.')
        public Boolean includeTermite;
        @InvocableVariable(label='Property Type' description='SingleFamily (default) or Townhome.')
        public String propertyType;
        @InvocableVariable(label='Override Reason' description='Required when the plan differs from the inspection\'s recommendation; why.')
        public String overrideReason;
    }

    @InvocableMethod(label='Verdant: Create quote' description='Creates the priced Revenue Cloud quote from the inspection (plan, add-on plans, one-time Initial Service). Use the plan, severity and add-on plans from the inspection\'s recommendation unless the technician chooses otherwise. Salesforce prices it; read the totals back from the result.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit, 'planSku' => r.planSku, 'squareFootage' => r.squareFootage, 'severity' => r.severity, 'includeMosquito' => r.includeMosquito, 'includeTermite' => r.includeTermite, 'propertyType' => r.propertyType, 'overrideReason' => r.overrideReason });
        }
        return RLM_RTK_McpTool.callEach('createQuote', params);
    }
}
