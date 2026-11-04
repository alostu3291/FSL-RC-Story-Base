/**
 * Creates a priced Brightline residential HVAC Quote in the field via Place Sales Transaction.
 * A comfort agreement is priced per system (quantity = systems in the home) and always comes with
 * the Initial Tune-up (HVAC-TUNEUP). Repairs and a replacement system are one-time lines. Applies
 * the location zone multiplier from RLM_HVAC_Service_Zone__c to list prices, and the equipment age
 * adjustment to the agreement.
 */
public with sharing class RLM_HVAC_FieldQuote {
    public static final String INITIAL_SKU = 'HVAC-TUNEUP';
    public static final String LOB = 'Residential HVAC';

    public class Request {
        @InvocableVariable public Id accountId;
        @InvocableVariable public String planSku;
        @InvocableVariable public String opportunityName;
        @InvocableVariable public String systemType;
        @InvocableVariable public String equipmentAge;
        @InvocableVariable public Integer systemCount;
        @InvocableVariable public Boolean includeIaq;
        @InvocableVariable public Boolean includeWaterHeater;
        /** Comma-separated one-time repair SKUs to quote with the agreement. */
        @InvocableVariable public String repairSkus;
        /** Optional good / better / best replacement system SKU. */
        @InvocableVariable public String replacementSku;
        @InvocableVariable public Id assessmentId;
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

    @InvocableMethod(label='Create Brightline Field Quote' category='Brightline'
        description='Places a priced residential HVAC Quote for the account: comfort agreement per system, Initial Tune-up, add-ons, repairs and an optional replacement, with location pricing.')
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
            RLM_HVAC_ZonePricing.ZoneResult zone = RLM_HVAC_ZonePricing.resolve(account.ShippingPostalCode);
            response.zoneCode = zone.zoneCode;
            response.zoneMultiplier = zone.multiplier;

            Boolean hasPlan = String.isNotBlank(request.planSku);
            Integer systems = systemsOf(request.systemCount);
            List<String> skus = new List<String>();
            if (hasPlan) {
                skus.add(request.planSku);
                skus.add(INITIAL_SKU);
                if (request.includeIaq == true) {
                    skus.add('HVAC-IAQ');
                }
                if (request.includeWaterHeater == true) {
                    skus.add('HVAC-WATER-HEATER');
                }
            }
            for (String sku : splitSkus(request.repairSkus)) {
                if (!skus.contains(sku)) {
                    skus.add(sku);
                }
            }
            if (String.isNotBlank(request.replacementSku)) {
                skus.add(request.replacementSku);
            }
            if (skus.isEmpty()) {
                response.message = 'Choose an agreement, a repair or a replacement to quote.';
                return response;
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
            if (hasPlan && (!entries.containsKey(request.planSku) || !entries.containsKey(INITIAL_SKU))) {
                response.message = 'Missing price book entries for the agreement or Initial Tune-up';
                return response;
            }
            if (entries.isEmpty()) {
                response.message = 'Missing price book entries for ' + String.join(skus, ', ');
                return response;
            }

            String oppName = String.isBlank(request.opportunityName)
                ? account.Name + (hasPlan ? ' - Comfort Agreement' : ' - Replacement')
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
            PricebookEntry anyEntry = entries.values()[0];
            RevSalesTrxn.RecordResource quoteRecord = new RevSalesTrxn.RecordResource(Quote.SObjectType, 'POST');
            quoteRecord.fieldValues = new Map<String, Object>{
                'Name' => oppName,
                'OpportunityId' => opportunity.Id,
                'QuoteAccountId' => account.Id,
                'Pricebook2Id' => anyEntry.Pricebook2Id,
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
            Decimal adjustment = adjustmentFor(request.equipmentAge);
            Integer i = 1;
            for (String sku : skus) {
                PricebookEntry entry = entries.get(sku);
                if (entry == null) {
                    continue;
                }
                Decimal unitPrice = RLM_HVAC_ZonePricing.apply(entry.UnitPrice, zone.multiplier);
                String description = entry.Product2.Description == null ? '' : entry.Product2.Description;
                Integer quantity = 1;
                if (sku == request.planSku) {
                    unitPrice = applyAgeAdjustment(unitPrice, request.equipmentAge);
                    quantity = systems;
                    if (adjustment > 0) {
                        description = (description + ' Includes a ' + money(adjustment)
                            + '/mo per system equipment age adjustment (' + adjustmentReasons(request.equipmentAge) + ').').trim();
                    }
                } else if (sku == INITIAL_SKU) {
                    quantity = systems;
                }
                RevSalesTrxn.RecordResource line = new RevSalesTrxn.RecordResource(QuoteLineItem.SObjectType, 'POST');
                Map<String, Object> fields = new Map<String, Object>{
                    'QuoteId' => '@{refQuote.id}',
                    'Product2Id' => entry.Product2Id,
                    'PricebookEntryId' => entry.Id,
                    'Quantity' => String.valueOf(quantity),
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

            RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('hvacFieldQuote', graphRecords);
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
            if (request.assessmentId != null && hasPlan) {
                RLM_HVAC_Assessment.markQuoted(request.assessmentId, response.quoteId, request.overrideReason);
                update new RLM_HVAC_Assessment__c(Id = request.assessmentId, Equipment_Age__c = request.equipmentAge,
                    System_Type__c = request.systemType, System_Count__c = systems, Age_Adjustment__c = adjustment);
            }
            response.success = true;
            response.message = 'Quote created with zone ' + zone.zoneCode + ' x' + String.valueOf(zone.multiplier);
        } catch (Exception e) {
            response.message = e.getMessage();
        }
        return response;
    }

    private static Integer systemsOf(Integer count) {
        return count == null || count < 1 ? 1 : count;
    }

    public static List<String> splitSkus(String csv) {
        List<String> out = new List<String>();
        if (String.isBlank(csv)) {
            return out;
        }
        for (String part : csv.split(',')) {
            if (String.isNotBlank(part) && !out.contains(part.trim())) {
                out.add(part.trim());
            }
        }
        return out;
    }

    // ---------- equipment age adjustment ----------

    /** Monthly amount per system added to the agreement for the age band of the oldest system. */
    public static final Map<String, Decimal> AGE_ADJUSTMENTS = new Map<String, Decimal>{
        '0to5' => 0, '6to10' => 3, '11to15' => 6, 'Over15' => 10
    };
    private static final Map<String, String> AGE_LABELS = new Map<String, String>{
        '0to5' => '0–5 years old', '6to10' => '6–10 years old', '11to15' => '11–15 years old', 'Over15' => 'over 15 years old'
    };

    /** Age band for equipment of this age in years. */
    public static String ageBand(Integer years) {
        if (years == null || years <= 5) {
            return '0to5';
        }
        if (years <= 10) {
            return '6to10';
        }
        return years <= 15 ? '11to15' : 'Over15';
    }

    public static Decimal adjustmentFor(String equipmentAge) {
        Decimal age = AGE_ADJUSTMENTS.get(equipmentAge);
        return (age == null ? 0 : age).setScale(2);
    }

    /** "equipment 11–15 years old +$6", or blank when the age band adds nothing. */
    public static String adjustmentReasons(String equipmentAge) {
        Decimal age = AGE_ADJUSTMENTS.get(equipmentAge);
        if (age == null || age <= 0) {
            return '';
        }
        return 'equipment ' + AGE_LABELS.get(equipmentAge) + ' +' + money(age);
    }

    public static String money(Decimal amount) {
        Decimal rounded = amount.setScale(2);
        return '$' + (rounded == rounded.setScale(0, RoundingMode.DOWN) ? String.valueOf(rounded.setScale(0)) : String.valueOf(rounded));
    }

    @TestVisible
    private static Decimal applyAgeAdjustment(Decimal base, String equipmentAge) {
        return ((base == null ? 0 : base) + adjustmentFor(equipmentAge)).setScale(2, RoundingMode.HALF_UP);
    }

    public class Pricing {
        @AuraEnabled public String zoneName;
        @AuraEnabled public Decimal zoneMultiplier;
        /** SKU to monthly (or one-time) price for the zone, before any equipment age adjustment. */
        @AuraEnabled public Map<String, Decimal> zonePrices = new Map<String, Decimal>();
        @AuraEnabled public Map<String, Decimal> listPrices = new Map<String, Decimal>();
        @AuraEnabled public Map<String, Decimal> ageAdjustments = AGE_ADJUSTMENTS;
    }

    /** What the quote screen needs to show how the price is built for this service ZIP. */
    @AuraEnabled(cacheable=true)
    public static Pricing pricingFor(String postalCode) {
        try {
            RLM_HVAC_ZonePricing.ZoneResult zone = RLM_HVAC_ZonePricing.resolve(postalCode);
            Pricing pricing = new Pricing();
            pricing.zoneName = zone.zoneName;
            pricing.zoneMultiplier = zone.multiplier;
            for (PricebookEntry entry : [
                SELECT UnitPrice, Product2.StockKeepingUnit FROM PricebookEntry
                WHERE Product2.StockKeepingUnit LIKE 'HVAC-%' AND Pricebook2.IsStandard = true
                    AND CurrencyIsoCode = 'USD' AND IsActive = true
            ]) {
                pricing.listPrices.put(entry.Product2.StockKeepingUnit, entry.UnitPrice);
                pricing.zonePrices.put(entry.Product2.StockKeepingUnit, RLM_HVAC_ZonePricing.apply(entry.UnitPrice, zone.multiplier));
            }
            return pricing;
        } catch (Exception e) {
            AuraHandledException error = new AuraHandledException(e.getMessage());
            error.setMessage(e.getMessage());
            throw error;
        }
    }
}
