/** Verdant hosted MCP tool get_visit_brief. */
public with sharing class RLM_RTK_McpGetVisitBrief {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
        @InvocableVariable(label='Regenerate' description='True to write a fresh brief.')
        public Boolean regenerate;
    }

    @InvocableMethod(label='Verdant: Get visit brief' description='A short pre-visit brief: who the customer is, their plans, history and what to look for.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit, 'regenerate' => r.regenerate });
        }
        return RLM_RTK_McpTool.callEach('visitBrief', params);
    }
}
