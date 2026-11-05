/**
 * Brightline Commercial pricing rules. A contract covers every rooftop unit at every site of a
 * property group: planned maintenance per unit by tonnage band, an optional filter program per
 * unit, and response coverage per site from its site type. Contracts run 12 months and renew
 * with an annual price increase.
 */
public with sharing class RLM_HVAC_CommercialPricing {
    public static final String FILTER_SKU = 'HVAC-COM-FILTER';
    public static final String RESPONSE_PRIORITY_SKU = 'HVAC-COM-RESP-4H';
    public static final String RESPONSE_STANDARD_SKU = 'HVAC-COM-RESP-NBD';
    public static final String LOB = 'Commercial HVAC';
    public static final String PAYMENT_TERMS = 'Net 30';
    public static final Integer TERM_MONTHS = 12;
    /** Line discounts at or above this percent route the quote to manager approval. */
    public static final Decimal APPROVAL_DISCOUNT = 15;
    /** Annual price increase applied at renewal, in percent. */
    public static final Decimal RENEWAL_UPLIFT = 3;

    public static final List<String> BAND_SKUS = new List<String>{
        'HVAC-COM-PM-S', 'HVAC-COM-PM-M', 'HVAC-COM-PM-L', 'HVAC-COM-PM-XL'
    };

    /** Planned maintenance SKU for a unit's tonnage; matches Asset.RLM_HVAC_Tonnage_Band__c. */
    public static String bandSku(Decimal tons) {
        if (tons == null || tons <= 5) {
            return 'HVAC-COM-PM-S';
        }
        if (tons <= 12) {
            return 'HVAC-COM-PM-M';
        }
        if (tons <= 25) {
            return 'HVAC-COM-PM-L';
        }
        return 'HVAC-COM-PM-XL';
    }

    /** Response coverage SKU for a site; matches Account.RLM_HVAC_Response_Tier__c. Null for HQ. */
    public static String responseSku(String siteType) {
        if (siteType == 'Restaurant' || siteType == 'Data Room') {
            return RESPONSE_PRIORITY_SKU;
        }
        if (String.isBlank(siteType) || siteType == 'Headquarters') {
            return null;
        }
        return RESPONSE_STANDARD_SKU;
    }

    /** Response time in hours for a response coverage SKU; next business day is 24. */
    public static Integer responseHours(String sku) {
        return sku == RESPONSE_PRIORITY_SKU ? 4 : 24;
    }

    /** True for a site response coverage SKU (4-hour or next business day). */
    public static Boolean isResponse(String sku) {
        return sku != null && sku.startsWith('HVAC-COM-RESP-');
    }

    public static Boolean needsApproval(Decimal discountPercent) {
        return discountPercent != null && discountPercent >= APPROVAL_DISCOUNT;
    }

    /** Discounts apply to per-unit maintenance and filters, not to response coverage. */
    public static Boolean isDiscountable(String sku) {
        return sku == FILTER_SKU || BAND_SKUS.contains(sku);
    }

    public static Decimal discounted(Decimal unitPrice, Decimal discountPercent) {
        if (unitPrice == null) {
            return 0;
        }
        if (discountPercent == null || discountPercent <= 0) {
            return unitPrice;
        }
        return (unitPrice * (1 - discountPercent / 100)).setScale(2, System.RoundingMode.HALF_UP);
    }

    /** The renewal price for a unit price after the annual increase. */
    public static Decimal renewalPrice(Decimal unitPrice) {
        return (unitPrice * (1 + RENEWAL_UPLIFT / 100)).setScale(2, System.RoundingMode.HALF_UP);
    }

    /** Contract start: the first of next month, so billing lines up with the calendar. */
    public static Date defaultStart(Date today) {
        return today.toStartOfMonth().addMonths(1);
    }

    public static Date endFor(Date startDate) {
        return startDate.addMonths(TERM_MONTHS).addDays(-1);
    }
}
