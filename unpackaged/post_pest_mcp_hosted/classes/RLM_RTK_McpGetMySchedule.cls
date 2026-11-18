/** Verdant hosted MCP tool get_my_schedule. */
public with sharing class RLM_RTK_McpGetMySchedule {
    public class Request {
        @InvocableVariable(label='Day' description='Day as YYYY-MM-DD, or today / tomorrow. Central time.')
        public String day;
    }

    @InvocableMethod(label='Verdant: Get my schedule' description='The technician\'s visits for a day (default today), in order, with customer, address and visit Ids.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'day' => r.day });
        }
        return RLM_RTK_McpTool.callEach('schedule', params);
    }
}
