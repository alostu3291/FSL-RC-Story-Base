/** Verdant hosted MCP tool start_visit. */
public with sharing class RLM_RTK_McpStartVisit {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
    }

    @InvocableMethod(label='Verdant: Start visit' description='Starts the visit when the technician arrives. On an inspection visit this opens the inspection.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit });
        }
        return RLM_RTK_McpTool.callEach('startVisit', params);
    }
}
