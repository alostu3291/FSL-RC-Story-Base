/** Verdant hosted MCP tool send_visit_summary. */
public with sharing class RLM_RTK_McpSendVisitSummary {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
    }

    @InvocableMethod(label='Verdant: Send visit summary' description='Writes the customer\'s visit summary and emails it to them. Only after complete_visit. If emailError says the record was locked, Salesforce is still processing the visit: try again in a minute.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit });
        }
        return RLM_RTK_McpTool.callEach('visitSummary', params);
    }
}
