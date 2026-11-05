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

// --- Capital projects: 40% deposit at booking, 40% at install, 20% at commissioning ---
// RLM_HVAC_CapitalProject accomplishes each milestone; the install and commissioning milestones
// carry the names of the DRO steps their work orders complete.
final String PROJECT_POLICY = 'Capital Project Milestone Billing Policy';
final String PROJECT_TREATMENT = 'Capital Project Milestone Billing Treatment';
final Set<String> PROJECT_SKUS = new Set<String>{ 'HVAC-COM-RTU-REPL', 'HVAC-COM-CRANE' };
// Milestone name => percentage, in billing order
final Map<String, Decimal> PROJECT_MILESTONES = new Map<String, Decimal>{
    'Project Deposit' => 40,
    'Rooftop Install Complete' => 40,
    'Commissioning Complete' => 20
};

List<BillingPolicy> projectPolicies = [
    SELECT Id, Status, DefaultBillingTreatmentId FROM BillingPolicy WHERE Name = :PROJECT_POLICY LIMIT 1
];
BillingPolicy projectPolicy;
if (projectPolicies.isEmpty()) {
    projectPolicy = new BillingPolicy(Name = PROJECT_POLICY, Status = 'Draft', BillingTreatmentSelection = 'Default',
        Description = 'Bill a capital project 40% at booking, 40% when the units are installed and 20% at commissioning');
    insert projectPolicy;
} else {
    projectPolicy = projectPolicies[0];
}
List<BillingTreatment> projectTreatments = [SELECT Id, Status FROM BillingTreatment WHERE Name = :PROJECT_TREATMENT LIMIT 1];
BillingTreatment projectTreatment;
if (projectTreatments.isEmpty()) {
    projectTreatment = new BillingTreatment(Name = PROJECT_TREATMENT, BillingPolicyId = projectPolicy.Id,
        IsMilestoneBilling = true, ExcludeFromBilling = 'No', CanChangeBillingFrequency = false, Status = 'Draft');
    insert projectTreatment;
} else {
    projectTreatment = projectTreatments[0];
}
Map<String, BillingTreatmentItem> projectItems = new Map<String, BillingTreatmentItem>();
for (BillingTreatmentItem i : [SELECT Id, Name, Status FROM BillingTreatmentItem WHERE BillingTreatmentId = :projectTreatment.Id]) {
    projectItems.put(i.Name, i);
}
Integer order = 0;
List<BillingTreatmentItem> newItems = new List<BillingTreatmentItem>();
for (String name : PROJECT_MILESTONES.keySet()) {
    order++;
    if (!projectItems.containsKey(name)) {
        newItems.add(new BillingTreatmentItem(Name = name, BillingTreatmentId = projectTreatment.Id, Type = 'Percentage',
            Percentage = PROJECT_MILESTONES.get(name), MilestoneType = 'Event', BillingType = 'None', Controller = 'None',
            Handling0Amount = 'None', Sequencing = 'None', ProcessingOrder = order, Status = 'Draft',
            Description = 'Bill ' + PROJECT_MILESTONES.get(name) + '% at ' + name.toLowerCase()));
    }
}
insert newItems;
List<BillingTreatmentItem> activateItems = new List<BillingTreatmentItem>();
for (BillingTreatmentItem i : [SELECT Id, Status FROM BillingTreatmentItem WHERE BillingTreatmentId = :projectTreatment.Id]) {
    if (i.Status != 'Active') {
        i.Status = 'Active';
        activateItems.add(i);
    }
}
update activateItems;
if (projectTreatment.Status != 'Active') {
    projectTreatment.Status = 'Active';
    update projectTreatment;
}
if (projectPolicy.DefaultBillingTreatmentId != projectTreatment.Id || projectPolicy.Status != 'Active') {
    projectPolicy.DefaultBillingTreatmentId = projectTreatment.Id;
    projectPolicy.Status = 'Active';
    update projectPolicy;
}
List<Product2> projectProducts = [
    SELECT Id FROM Product2 WHERE StockKeepingUnit IN :PROJECT_SKUS AND BillingPolicyId != :projectPolicy.Id
];
for (Product2 p : projectProducts) {
    p.BillingPolicyId = projectPolicy.Id;
}
update projectProducts;

System.debug('setupHvacCommercialRevenue complete: prices inserted=' + newPrices.size()
    + ', products given billing and tax policies=' + policiesSet
    + ', capital project milestones added=' + newItems.size() + ', products moved to them=' + projectProducts.size());
