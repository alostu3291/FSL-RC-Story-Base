// Idempotent Brightline Commercial revenue setup, run after the hvac-com-pcm catalog load:
//  1. Price book entries for HVAC-COM-* products (planned maintenance per unit per month,
//     response coverage per site per month, one-time services, repairs and capital items)
//  2. Billing and tax policies copied from the residential agreement where missing

final Map<String, Decimal> PRICES = new Map<String, Decimal>{
    'HVAC-COM-PM-S' => 38,
    'HVAC-COM-PM-M' => 55,
    'HVAC-COM-PM-L' => 85,
    'HVAC-COM-PM-XL' => 130,
    'HVAC-COM-FILTER' => 9,
    'HVAC-COM-RESP-4H' => 175,
    'HVAC-COM-RESP-NBD' => 45,
    'HVAC-COM-SURVEY' => 0,
    'HVAC-COM-LABOR' => 165,
    'HVAC-COM-BELT' => 85,
    'HVAC-COM-LEAK-REPAIR' => 750,
    'HVAC-COM-REFRIGERANT' => 95,
    'HVAC-COM-COMPRESSOR' => 4200,
    'HVAC-COM-RTU-REPL' => 16800,
    'HVAC-COM-CRANE' => 2600
};
final Set<String> TERM_SKUS = new Set<String>{
    'HVAC-COM-PM-S', 'HVAC-COM-PM-M', 'HVAC-COM-PM-L', 'HVAC-COM-PM-XL',
    'HVAC-COM-FILTER', 'HVAC-COM-RESP-4H', 'HVAC-COM-RESP-NBD'
};

ProductSellingModel termMonthly;
ProductSellingModel oneTime;
for (ProductSellingModel m : [
    SELECT Id, Name, SellingModelType FROM ProductSellingModel
    WHERE Status = 'Active' AND Name IN ('Term Monthly', 'One-Time')
]) {
    if (m.SellingModelType == 'TermDefined') {
        termMonthly = m;
    } else if (m.SellingModelType == 'OneTime') {
        oneTime = m;
    }
}
if (termMonthly == null || oneTime == null) {
    throw new IllegalArgumentException('Missing the Term Monthly or One-Time selling model; load hvac-com-pcm first.');
}

Pricebook2 standardBook = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
Map<String, Id> productIdBySku = new Map<String, Id>();
for (Product2 p : [SELECT Id, StockKeepingUnit FROM Product2 WHERE StockKeepingUnit IN :PRICES.keySet()]) {
    productIdBySku.put(p.StockKeepingUnit, p.Id);
}

Set<String> existingKeys = new Set<String>();
for (PricebookEntry e : [
    SELECT Product2.StockKeepingUnit, ProductSellingModelId FROM PricebookEntry
    WHERE Product2.StockKeepingUnit IN :PRICES.keySet()
        AND Pricebook2Id = :standardBook.Id AND CurrencyIsoCode = 'USD'
]) {
    existingKeys.add(e.Product2.StockKeepingUnit + ':' + e.ProductSellingModelId);
}
List<PricebookEntry> newPrices = new List<PricebookEntry>();
for (String sku : PRICES.keySet()) {
    Id productId = productIdBySku.get(sku);
    if (productId == null) {
        continue;
    }
    Id modelId = TERM_SKUS.contains(sku) ? termMonthly.Id : oneTime.Id;
    if (existingKeys.contains(sku + ':' + modelId)) {
        continue;
    }
    newPrices.add(new PricebookEntry(
        Product2Id = productId,
        Pricebook2Id = standardBook.Id,
        ProductSellingModelId = modelId,
        CurrencyIsoCode = 'USD',
        UnitPrice = PRICES.get(sku),
        IsActive = true
    ));
}
insert newPrices;

List<Product2> template = [
    SELECT BillingPolicyId, TaxPolicyId FROM Product2
    WHERE StockKeepingUnit = 'HVAC-BASIC' AND BillingPolicyId != null LIMIT 1
];
Integer policiesSet = 0;
if (!template.isEmpty()) {
    List<Product2> toUpdate = new List<Product2>();
    for (Product2 p : [
        SELECT Id, BillingPolicyId, TaxPolicyId FROM Product2
        WHERE StockKeepingUnit LIKE 'HVAC-COM-%' AND (BillingPolicyId = null OR TaxPolicyId = null)
    ]) {
        p.BillingPolicyId = p.BillingPolicyId == null ? template[0].BillingPolicyId : p.BillingPolicyId;
        p.TaxPolicyId = p.TaxPolicyId == null ? template[0].TaxPolicyId : p.TaxPolicyId;
        toUpdate.add(p);
    }
    update toUpdate;
    policiesSet = toUpdate.size();
}

System.debug('setupHvacCommercialRevenue complete: prices inserted=' + newPrices.size()
    + ', products given billing and tax policies=' + policiesSet);
