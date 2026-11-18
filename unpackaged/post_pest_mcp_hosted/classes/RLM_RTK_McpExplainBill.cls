/** Verdant hosted MCP tool explain_bill. */
public with sharing class RLM_RTK_McpExplainBill {
    public class Request {
        @InvocableVariable(label='Customer' description='Customer name as it appears in Salesforce (for example Sam Patel) or an Account Id.' required=true)
        public String customer;
        @InvocableVariable(label='Amount' description='The bill amount they\'re asking about, if they said one.')
        public String amount;
        @InvocableVariable(label='Invoice Number' description='The invoice number, if they gave one.')
        public String invoiceNumber;
    }

    @InvocableMethod(label='Verdant: Explain bill' description='Explains a customer\'s invoice line by line (plans, proration, add-ons, tax). Invoices are generated automatically from the plans; this only reads them.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'customer' => r.customer, 'amount' => r.amount, 'invoiceNumber' => r.invoiceNumber });
        }
        return RLM_RTK_McpTool.callEach('explainBill', params);
    }
}
