/**
 * Creates a priced Rentokil residential Quote in the field via Place Sales Transaction.
 * Always includes Initial Service (RTK-INITIAL) with the selected plan. Applies location
 * zone multiplier from RLM_RTK_Service_Zone__c to list prices before pricing.
 */
public with sharing class RLM_RTK_FieldQuote {
    public static final String INITIAL_SKU = 'RTK-INITIAL';
    public static final String LOB = 'Residential Pest';

    public class Request {
        @InvocableVariable(required=true) public Id accountId;
        @InvocableVariable(required=true) public String planSku;
        @InvocableVariable public String opportunityName;
        @InvocableVariable public String propertyType;
        @InvocableVariable public String squareFootage;
        @InvocableVariable public String severity;
        @InvocableVariable public Boolean includeMosquito;
        @InvocableVariable public Boolean includeTermite;
        @InvocableVariable public Id inspectionId;
        @InvocableVariable public String overrideReason;
    }

    public class Response {
        @InvocableVariable public Id quoteId;
        @InvocableVariable public Id opportunityId;
        @InvocableVariable public String zoneCode;
        @InvocableVariable public Decimal zoneMultiplier;
        @InvocableVariable public String message;
        @InvocableVariable public Boolean success;
    }

    @InvocableMethod(label='Create Rentokil Field Quote' category='Rentokil'
        description='Places a priced residential pest Quote for the account, including Initial Service and location pricing.')
    public static List<Response> createQuotes(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request request : requests) {
            responses.add(createQuote(request));
        }
        return responses;
    }

    public static Response createQuote(Request request) {
        Response response = new Response();
        response.success = false;
        try {
            Account account = [
                SELECT Id, Name, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                    BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry
                FROM Account WHERE Id = :request.accountId
            ];
            RLM_RTK_ZonePricing.ZoneResult zone = RLM_RTK_ZonePricing.resolve(account.ShippingPostalCode);
            response.zoneCode = zone.zoneCode;
            response.zoneMultiplier = zone.multiplier;

            List<String> skus = new List<String>{ request.planSku, INITIAL_SKU };
            if (request.includeMosquito == true) {
                skus.add('RTK-MOSQUITO');
            }
            if (request.includeTermite == true) {
                skus.add('RTK-TERMITE');
            }

            Map<String, PricebookEntry> entries = new Map<String, PricebookEntry>();
            for (PricebookEntry entry : [
                SELECT Id, UnitPrice, Product2Id, Pricebook2Id, Product2.StockKeepingUnit, Product2.Description,
                    ProductSellingModel.SellingModelType
                FROM PricebookEntry
                WHERE Product2.StockKeepingUnit IN :skus AND Pricebook2.IsStandard = true
                    AND CurrencyIsoCode = 'USD' AND IsActive = true
            ]) {
                entries.put(entry.Product2.StockKeepingUnit, entry);
            }
            if (!entries.containsKey(request.planSku) || !entries.containsKey(INITIAL_SKU)) {
                response.message = 'Missing price book entries for plan or Initial Service';
                return response;
            }

            String oppName = String.isBlank(request.opportunityName)
                ? account.Name + ' - Residential Pest'
                : request.opportunityName;
            Opportunity opportunity = new Opportunity(
                Name = oppName,
                AccountId = account.Id,
                StageName = 'Qualification',
                CloseDate = Date.today().addDays(14)
            );
            insert opportunity;
            response.opportunityId = opportunity.Id;

            String today = String.valueOf(Date.today());
            PricebookEntry planEntry = entries.get(request.planSku);
            RevSalesTrxn.RecordResource quoteRecord = new RevSalesTrxn.RecordResource(Quote.SObjectType, 'POST');
            quoteRecord.fieldValues = new Map<String, Object>{
                'Name' => oppName,
                'OpportunityId' => opportunity.Id,
                'QuoteAccountId' => account.Id,
                'Pricebook2Id' => planEntry.Pricebook2Id,
                'RLM_Line_of_Business__c' => LOB,
                'ShippingStreet' => account.ShippingStreet,
                'ShippingCity' => account.ShippingCity,
                'ShippingState' => account.ShippingState,
                'ShippingPostalCode' => account.ShippingPostalCode,
                'ShippingCountry' => account.ShippingCountry,
                'BillingStreet' => account.BillingStreet,
                'BillingCity' => account.BillingCity,
                'BillingState' => account.BillingState,
                'BillingPostalCode' => account.BillingPostalCode,
                'BillingCountry' => account.BillingCountry
            };

            List<RevSalesTrxn.RecordWithReferenceRequest> graphRecords =
                new List<RevSalesTrxn.RecordWithReferenceRequest>{
                    new RevSalesTrxn.RecordWithReferenceRequest('refQuote', quoteRecord)
                };
            Decimal adjustment = adjustmentFor(request.severity, request.squareFootage);
            Integer i = 1;
            for (String sku : skus) {
                PricebookEntry entry = entries.get(sku);
                if (entry == null) {
                    continue;
                }
                Decimal unitPrice = RLM_RTK_ZonePricing.apply(entry.UnitPrice, zone.multiplier);
                String description = entry.Product2.Description == null ? '' : entry.Product2.Description;
                if (sku == request.planSku) {
                    unitPrice = applyAttributeUplift(unitPrice, request.severity, request.squareFootage);
                    if (adjustment > 0) {
                        description = (description + ' Includes a ' + money(adjustment)
                            + '/mo size and severity adjustment (' + adjustmentReasons(request.severity, request.squareFootage) + ').').trim();
                    }
                }
                RevSalesTrxn.RecordResource line = new RevSalesTrxn.RecordResource(QuoteLineItem.SObjectType, 'POST');
                Map<String, Object> fields = new Map<String, Object>{
                    'QuoteId' => '@{refQuote.id}',
                    'Product2Id' => entry.Product2Id,
                    'PricebookEntryId' => entry.Id,
                    'Quantity' => '1',
                    'UnitPrice' => String.valueOf(unitPrice),
                    'StartDate' => today,
                    'Description' => description.abbreviate(255)
                };
                if (entry.ProductSellingModel != null && entry.ProductSellingModel.SellingModelType == 'Evergreen') {
                    fields.put('PeriodBoundary', 'Anniversary');
                    fields.put('BillingFrequency', 'Monthly');
                }
                line.fieldValues = fields;
                graphRecords.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine' + i, line));
                i++;
            }

            RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('rtkFieldQuote', graphRecords);
            RevSalesTrxn.PlaceSalesTransactionResponse pstResponse =
                RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                    graph,
                    RevSalesTrxn.PricingPreferenceEnum.SYSTEM,
                    RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                    new RevSalesTrxn.ConfigurationOptionsInput(),
                    null,
                    null,
                    RevSalesTrxn.TaxPreferenceEnum.SKIP,
                    null
                );
            if (pstResponse == null || pstResponse.isSuccess != true || String.isBlank(pstResponse.salesTransactionId)) {
                response.message = 'Place Sales Transaction failed: ' +
                    (pstResponse == null ? 'null' : JSON.serialize(pstResponse.errorResponse));
                return response;
            }
            response.quoteId = pstResponse.salesTransactionId;
            if (request.inspectionId != null) {
                RLM_RTK_Inspection.markQuoted(request.inspectionId, response.quoteId, request.overrideReason);
                update new RLM_RTK_Inspection__c(Id = request.inspectionId, Home_Size__c = request.squareFootage,
                    Priced_Severity__c = request.severity, Size_Severity_Adjustment__c = adjustment);
            }
            response.success = true;
            response.message = 'Quote created with zone ' + zone.zoneCode + ' x' + String.valueOf(zone.multiplier);
        } catch (Exception e) {
            response.message = e.getMessage();
        }
        return response;
    }

    // ---------- size and severity adjustment ----------

    /** Monthly amount added to the plan tier for the home's size bucket. */
    public static final Map<String, Decimal> SIZE_ADJUSTMENTS = new Map<String, Decimal>{
        'Under2000' => 0, '2000to3500' => 10, 'Over3500' => 20
    };
    /** Monthly amount added to the plan tier for the infestation severity. */
    public static final Map<String, Decimal> SEVERITY_ADJUSTMENTS = new Map<String, Decimal>{
        'Light' => 0, 'Moderate' => 10, 'Heavy' => 25
    };
    private static final Map<String, String> SIZE_LABELS = new Map<String, String>{
        'Under2000' => 'under 2,000 sq ft', '2000to3500' => '2,000–3,500 sq ft', 'Over3500' => 'over 3,500 sq ft'
    };

    public static Decimal adjustmentFor(String severity, String squareFootage) {
        Decimal size = SIZE_ADJUSTMENTS.get(squareFootage);
        Decimal sev = SEVERITY_ADJUSTMENTS.get(severity);
        return ((size == null ? 0 : size) + (sev == null ? 0 : sev)).setScale(2);
    }

    /** "2,000–3,500 sq ft +$10, Moderate severity +$10", listing only the parts that add to the price. */
    public static String adjustmentReasons(String severity, String squareFootage) {
        List<String> parts = new List<String>();
        Decimal size = SIZE_ADJUSTMENTS.get(squareFootage);
        if (size != null && size > 0) {
            parts.add(SIZE_LABELS.get(squareFootage) + ' +' + money(size));
        }
        Decimal sev = SEVERITY_ADJUSTMENTS.get(severity);
        if (sev != null && sev > 0) {
            parts.add(severity + ' severity +' + money(sev));
        }
        return String.join(parts, ', ');
    }

    public static String money(Decimal amount) {
        Decimal rounded = amount.setScale(2);
        return '$' + (rounded == rounded.setScale(0, RoundingMode.DOWN) ? String.valueOf(rounded.setScale(0)) : String.valueOf(rounded));
    }

    @TestVisible
    private static Decimal applyAttributeUplift(Decimal base, String severity, String squareFootage) {
        return ((base == null ? 0 : base) + adjustmentFor(severity, squareFootage)).setScale(2, RoundingMode.HALF_UP);
    }

    public class Pricing {
        @AuraEnabled public String zoneName;
        @AuraEnabled public Decimal zoneMultiplier;
        /** SKU to monthly (or one-time) price for the zone, before any size and severity adjustment. */
        @AuraEnabled public Map<String, Decimal> zonePrices = new Map<String, Decimal>();
        @AuraEnabled public Map<String, Decimal> listPrices = new Map<String, Decimal>();
        @AuraEnabled public Map<String, Decimal> sizeAdjustments = SIZE_ADJUSTMENTS;
        @AuraEnabled public Map<String, Decimal> severityAdjustments = SEVERITY_ADJUSTMENTS;
    }

    /** What the quote screen needs to show how the price is built for this service ZIP. */
    @AuraEnabled(cacheable=true)
    public static Pricing pricingFor(String postalCode) {
        try {
            RLM_RTK_ZonePricing.ZoneResult zone = RLM_RTK_ZonePricing.resolve(postalCode);
            Pricing pricing = new Pricing();
            pricing.zoneName = zone.zoneName;
            pricing.zoneMultiplier = zone.multiplier;
            for (PricebookEntry entry : [
                SELECT UnitPrice, Product2.StockKeepingUnit FROM PricebookEntry
                WHERE Product2.StockKeepingUnit IN :QUOTE_SKUS AND Pricebook2.IsStandard = true
                    AND CurrencyIsoCode = 'USD' AND IsActive = true
            ]) {
                pricing.listPrices.put(entry.Product2.StockKeepingUnit, entry.UnitPrice);
                pricing.zonePrices.put(entry.Product2.StockKeepingUnit, RLM_RTK_ZonePricing.apply(entry.UnitPrice, zone.multiplier));
            }
            return pricing;
        } catch (Exception e) {
            AuraHandledException error = new AuraHandledException(e.getMessage());
            error.setMessage(e.getMessage());
            throw error;
        }
    }

    private static final List<String> QUOTE_SKUS = new List<String>{
        'RTK-ESSENTIAL', 'RTK-HOME-PROT', 'RTK-HOME-PROT-PLUS', 'RTK-MOSQUITO', 'RTK-TERMITE', INITIAL_SKU
    };
}
