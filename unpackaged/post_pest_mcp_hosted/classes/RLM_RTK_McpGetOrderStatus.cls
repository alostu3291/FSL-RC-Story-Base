/** Verdant hosted MCP tool get_order_status. */
public with sharing class RLM_RTK_McpGetOrderStatus {
    public class Request {
        @InvocableVariable(label='Quote Id' description='The quote Id from create_quote.' required=true)
        public String quoteId;
    }

    @InvocableMethod(label='Verdant: Get order status' description='The order\'s status and the Initial Pest Treatment visit fulfillment created for it (treatmentAppointmentId).' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'quoteId' => r.quoteId });
        }
        return RLM_RTK_McpTool.callEach('orderStatus', params);
    }
}
