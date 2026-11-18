/** Verdant hosted MCP tool record_customer_acceptance. */
public with sharing class RLM_RTK_McpRecordAcceptance {
    public class Request {
        @InvocableVariable(label='Quote Id' description='The quote Id from create_quote.' required=true)
        public String quoteId;
        @InvocableVariable(label='Signer Name' description='Full name of the customer signing.' required=true)
        public String signerName;
        @InvocableVariable(label='Customer Statement' description='What the customer said to accept, in their words (for example Yes, let\'s do Home Protection).' required=true)
        public String customerStatement;
        @InvocableVariable(label='Card Last 4' description='Last four digits of the card on file, if given.')
        public String cardLast4;
        @InvocableVariable(label='Card Brand' description='Card brand, for example Visa.')
        public String cardBrand;
    }

    @InvocableMethod(label='Verdant: Record customer acceptance' description='Records the customer\'s signature on the proposal. Only after they\'ve seen the price and said yes.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'quoteId' => r.quoteId, 'signerName' => r.signerName, 'approvalStatement' => r.customerStatement, 'cardLast4' => r.cardLast4, 'cardBrand' => r.cardBrand });
        }
        return RLM_RTK_McpTool.callEach('acceptQuote', params);
    }
}
