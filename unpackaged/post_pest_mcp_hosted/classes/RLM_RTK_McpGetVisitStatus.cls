/** Verdant hosted MCP tool get_visit_status. */
public with sharing class RLM_RTK_McpGetVisitStatus {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
    }

    @InvocableMethod(label='Verdant: Get visit status' description='Where a visit stands: stage (start, walk, customer, order), inspection, quote, signature, order, timing.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit });
        }
        return RLM_RTK_McpTool.callEach('visitContext', params);
    }
}
