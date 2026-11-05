/**
 * Builds the Brightline Commercial planned maintenance contract for a property group: one quote on
 * the parent account, one quote line group per site, and per site a planned maintenance line per
 * tonnage band (quantity = units in that band), an optional filter program line and a response
 * coverage line from the site type. Lines run 12 months, billed monthly, on Net 30 terms; a
 * discount of 15% or more routes the quote to approval.
 */
public with sharing class RLM_HVAC_ContractQuote {

    public class Line {
        @AuraEnabled public String sku;
        @AuraEnabled public String name;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal monthly;
        @AuraEnabled public Decimal discountPercent;
        /** Unit tags the line covers, such as "RTU-01, RTU-02". */
        @AuraEnabled public String units;
    }

    public class Site {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String siteType;
        @AuraEnabled public String responseTier;
        @AuraEnabled public Integer unitCount = 0;
        @AuraEnabled public Decimal tons = 0;
        @AuraEnabled public Integer trackedUnits = 0;
        @AuraEnabled public Integer oldestYear;
        @AuraEnabled public Decimal monthly = 0;
        @AuraEnabled public List<Line> lines = new List<Line>();
    }

    public class Plan {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public List<Site> sites = new List<Site>();
        @AuraEnabled public Integer unitCount = 0;
        @AuraEnabled public Decimal tons = 0;
        @AuraEnabled public Decimal monthly = 0;
        @AuraEnabled public Decimal annual = 0;
        @AuraEnabled public Decimal discountPercent = 0;
        @AuraEnabled public Boolean filterProgram = true;
        @AuraEnabled public Boolean needsApproval = false;
        @AuraEnabled public String startDate;
        @AuraEnabled public String endDate;
        @AuraEnabled public String paymentTerms = RLM_HVAC_CommercialPricing.PAYMENT_TERMS;
        @AuraEnabled public String contactName;
        @AuraEnabled public Id openQuoteId;
        @AuraEnabled public String openQuoteName;
    }

    public class Result {
        @AuraEnabled @InvocableVariable public Id quoteId;
        @AuraEnabled @InvocableVariable public Boolean needsApproval;
        @AuraEnabled @InvocableVariable public Decimal monthly;
        @AuraEnabled @InvocableVariable public Decimal annual;
        @AuraEnabled @InvocableVariable public String message;
    }

    public class Request {
        @InvocableVariable(required=true) public Id accountId;
        @InvocableVariable public Boolean filterProgram;
        @InvocableVariable public Decimal discountPercent;
        @InvocableVariable public Date startDate;
    }

    /** The contract the quote would contain, for the builder screen. */
    @AuraEnabled
    public static Plan preview(Id accountId, Boolean filterProgram, Decimal discountPercent) {
        try {
            return planFor(accountId, filterProgram, discountPercent, null);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static Result createQuote(Id accountId, Boolean filterProgram, Decimal discountPercent, String startDate) {
        try {
            Date start = String.isBlank(startDate) ? null : Date.valueOf(startDate);
            return place(planFor(accountId, filterProgram, discountPercent, start));
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @InvocableMethod(label='Create Brightline Commercial Contract Quote' category='Brightline'
        description='Places the planned maintenance contract quote for a property group: a line group per site, maintenance per unit by tonnage band, filters and response coverage per site.')
    public static List<Result> createQuotes(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request r : requests) {
            results.add(place(planFor(r.accountId, r.filterProgram, r.discountPercent, r.startDate)));
        }
        return results;
    }

    public static Plan planFor(Id accountId, Boolean filterProgram, Decimal discountPercent, Date startDate) {
        Account parent = [SELECT Id, Name FROM Account WHERE Id = :accountId];
        List<Account> sites = [
            SELECT Id, Name, RLM_HVAC_Site_Type__c, RLM_HVAC_Response_Tier__c
            FROM Account WHERE ParentId = :accountId OR Id = :accountId
            ORDER BY RLM_HVAC_Site_Code__c NULLS LAST, Name
        ];
        Plan plan = planForSites(sites, filterProgram, discountPercent);
        plan.accountId = parent.Id;
        plan.accountName = parent.Name;
        Date start = startDate == null ? RLM_HVAC_CommercialPricing.defaultStart(Date.today()) : startDate;
        plan.startDate = String.valueOf(start);
        plan.endDate = String.valueOf(RLM_HVAC_CommercialPricing.endFor(start));
        Contact signer = signerFor(accountId);
        plan.contactName = signer == null ? null : signer.Name;
        for (Quote q : [
            SELECT Id, Name FROM Quote
            WHERE QuoteAccountId = :accountId AND RLM_Line_of_Business__c = :RLM_HVAC_CommercialPricing.LOB
                AND Status NOT IN ('Accepted', 'Rejected', 'Denied')
            ORDER BY CreatedDate DESC LIMIT 1
        ]) {
            plan.openQuoteId = q.Id;
            plan.openQuoteName = q.Name;
        }
        return plan;
    }

    /** The contract lines for these sites, from their rooftop units and the commercial price book. */
    /** Product SKUs are unique org-wide, so tests can't create the catalog's price book entries. */
    @TestVisible
    private static Map<String, Decimal> testPrices;

    public static Plan planForSites(List<Account> sites, Boolean filterProgram, Decimal discountPercent) {
        List<Asset> units = [
            SELECT Id, AccountId, RLM_HVAC_Unit_Tag__c, RLM_HVAC_Tonnage__c, RLM_HVAC_Install_Year__c,
                RLM_HVAC_Leak_Rate_Tracked__c
            FROM Asset
            WHERE AccountId IN :new Map<Id, Account>(sites).keySet() AND RLM_HVAC_Tonnage__c != null
                AND Status != 'Obsolete'
            ORDER BY RLM_HVAC_Unit_Tag__c
        ];
        Map<String, Decimal> prices = new Map<String, Decimal>();
        Map<String, String> names = new Map<String, String>();
        for (PricebookEntry e : [
            SELECT UnitPrice, Product2.StockKeepingUnit, Product2.Name FROM PricebookEntry
            WHERE Product2.StockKeepingUnit LIKE 'HVAC-COM-%' AND Pricebook2.IsStandard = true
                AND CurrencyIsoCode = 'USD' AND IsActive = true
        ]) {
            prices.put(e.Product2.StockKeepingUnit, e.UnitPrice);
            names.put(e.Product2.StockKeepingUnit, e.Product2.Name);
        }
        if (testPrices != null) {
            for (String sku : testPrices.keySet()) {
                prices.put(sku, testPrices.get(sku));
                names.put(sku, sku);
            }
        }
        return buildPlan(sites, units, prices, names, filterProgram != false, discountPercent);
    }

    /** Pure contract math: sites and their units in, priced lines per site out. */
    public static Plan buildPlan(List<Account> sites, List<Asset> units, Map<String, Decimal> prices,
            Map<String, String> names, Boolean filterProgram, Decimal discountPercent) {
        Plan plan = new Plan();
        plan.filterProgram = filterProgram;
        plan.discountPercent = discountPercent == null ? 0 : discountPercent;
        plan.needsApproval = RLM_HVAC_CommercialPricing.needsApproval(plan.discountPercent);
        Map<Id, List<Asset>> unitsBySite = new Map<Id, List<Asset>>();
        for (Asset u : units) {
            if (!unitsBySite.containsKey(u.AccountId)) {
                unitsBySite.put(u.AccountId, new List<Asset>());
            }
            unitsBySite.get(u.AccountId).add(u);
        }
        for (Account a : sites) {
            List<Asset> siteUnits = unitsBySite.get(a.Id);
            if (siteUnits == null || siteUnits.isEmpty()) {
                continue;
            }
            Site site = new Site();
            site.accountId = a.Id;
            site.name = a.Name;
            site.siteType = a.RLM_HVAC_Site_Type__c;
            site.responseTier = a.RLM_HVAC_Response_Tier__c;
            Map<String, List<String>> tagsBySku = new Map<String, List<String>>();
            for (Asset u : siteUnits) {
                site.unitCount++;
                site.tons += u.RLM_HVAC_Tonnage__c;
                if (u.RLM_HVAC_Leak_Rate_Tracked__c == true) {
                    site.trackedUnits++;
                }
                Integer year = u.RLM_HVAC_Install_Year__c == null ? null : u.RLM_HVAC_Install_Year__c.intValue();
                if (year != null && (site.oldestYear == null || year < site.oldestYear)) {
                    site.oldestYear = year;
                }
                String sku = RLM_HVAC_CommercialPricing.bandSku(u.RLM_HVAC_Tonnage__c);
                if (!tagsBySku.containsKey(sku)) {
                    tagsBySku.put(sku, new List<String>());
                }
                tagsBySku.get(sku).add(u.RLM_HVAC_Unit_Tag__c);
            }
            for (String sku : RLM_HVAC_CommercialPricing.BAND_SKUS) {
                if (tagsBySku.containsKey(sku)) {
                    addLine(site, sku, tagsBySku.get(sku), prices, names, plan.discountPercent);
                }
            }
            if (filterProgram) {
                List<String> all = new List<String>();
                for (Asset u : siteUnits) {
                    all.add(u.RLM_HVAC_Unit_Tag__c);
                }
                addLine(site, RLM_HVAC_CommercialPricing.FILTER_SKU, all, prices, names, plan.discountPercent);
            }
            String responseSku = RLM_HVAC_CommercialPricing.responseSku(site.siteType);
            if (responseSku != null) {
                addLine(site, responseSku, null, prices, names, plan.discountPercent);
            }
            plan.sites.add(site);
            plan.unitCount += site.unitCount;
            plan.tons += site.tons;
            plan.monthly += site.monthly;
        }
        plan.annual = plan.monthly * RLM_HVAC_CommercialPricing.TERM_MONTHS;
        return plan;
    }

    private static void addLine(Site site, String sku, List<String> tags, Map<String, Decimal> prices,
            Map<String, String> names, Decimal discountPercent) {
        if (!prices.containsKey(sku)) {
            throw new IllegalArgumentException('Missing a price for ' + sku + '; run setup_hvac_commercial_revenue.');
        }
        Line line = new Line();
        line.sku = sku;
        line.name = names.get(sku);
        line.quantity = tags == null ? 1 : tags.size();
        line.listPrice = prices.get(sku);
        line.discountPercent = RLM_HVAC_CommercialPricing.isDiscountable(sku) ? discountPercent : 0;
        line.unitPrice = RLM_HVAC_CommercialPricing.discounted(line.listPrice, line.discountPercent);
        line.monthly = line.unitPrice * line.quantity;
        line.units = tags == null ? null : String.join(tags, ', ');
        site.lines.add(line);
        site.monthly += line.monthly;
    }

    private static Result place(Plan plan) {
        Result result = new Result();
        result.needsApproval = plan.needsApproval;
        result.monthly = plan.monthly;
        result.annual = plan.annual;
        if (plan.sites.isEmpty()) {
            result.message = plan.accountName + ' has no sites with rooftop units to put under contract.';
            return result;
        }
        Account parent = [
            SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry
            FROM Account WHERE Id = :plan.accountId
        ];
        Map<String, PricebookEntry> entries = new Map<String, PricebookEntry>();
        for (PricebookEntry e : [
            SELECT Id, Product2Id, Pricebook2Id, Product2.StockKeepingUnit FROM PricebookEntry
            WHERE Product2.StockKeepingUnit LIKE 'HVAC-COM-%' AND Pricebook2.IsStandard = true
                AND CurrencyIsoCode = 'USD' AND IsActive = true
        ]) {
            entries.put(e.Product2.StockKeepingUnit, e);
        }
        Opportunity opportunity = new Opportunity(
            Name = parent.Name + ' - Planned Maintenance Contract',
            AccountId = parent.Id,
            StageName = 'Proposal/Price Quote',
            CloseDate = Date.today().addDays(30)
        );
        try {
            insert opportunity;
        } catch (DmlException e) {
            opportunity.StageName = 'Qualification';
            insert opportunity;
        }
        Contact signer = signerFor(parent.Id);

        RevSalesTrxn.RecordResource quote = new RevSalesTrxn.RecordResource(Quote.SObjectType, 'POST');
        Map<String, Object> quoteFields = new Map<String, Object>{
            'Name' => parent.Name + ' - Planned Maintenance Contract',
            'OpportunityId' => opportunity.Id,
            'QuoteAccountId' => parent.Id,
            'Pricebook2Id' => entries.values()[0].Pricebook2Id,
            'CurrencyIsoCode' => 'USD',
            'RLM_Line_of_Business__c' => RLM_HVAC_CommercialPricing.LOB,
            'RLM_Payment_Terms__c' => plan.paymentTerms,
            'RLM_TermMonths__c' => String.valueOf(RLM_HVAC_CommercialPricing.TERM_MONTHS),
            'ExpirationDate' => String.valueOf(Date.today().addDays(30)),
            'BillingStreet' => parent.BillingStreet,
            'BillingCity' => parent.BillingCity,
            'BillingState' => parent.BillingState,
            'BillingPostalCode' => parent.BillingPostalCode,
            'BillingCountry' => parent.BillingCountry,
            'ShippingStreet' => parent.ShippingStreet,
            'ShippingCity' => parent.ShippingCity,
            'ShippingState' => parent.ShippingState,
            'ShippingPostalCode' => parent.ShippingPostalCode,
            'ShippingCountry' => parent.ShippingCountry
        };
        if (signer != null) {
            quoteFields.put('ContactId', signer.Id);
        }
        quote.fieldValues = quoteFields;
        List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>{
            new RevSalesTrxn.RecordWithReferenceRequest('refQuote', quote)
        };
        Integer g = 0;
        Integer n = 0;
        for (Site site : plan.sites) {
            g++;
            RevSalesTrxn.RecordResource grp = new RevSalesTrxn.RecordResource(QuoteLineGroup.SObjectType, 'POST');
            grp.fieldValues = new Map<String, Object>{
                'QuoteId' => '@{refQuote.id}',
                'Name' => site.name,
                'SortOrder' => String.valueOf(g),
                'Description' => (site.unitCount + ' units, ' + site.tons.stripTrailingZeros().toPlainString()
                    + ' tons' + (String.isBlank(site.responseTier) ? '' : ', ' + site.responseTier + ' response')).abbreviate(255)
            };
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refGroup' + g, grp));
            for (Line line : site.lines) {
                n++;
                PricebookEntry entry = entries.get(line.sku);
                RevSalesTrxn.RecordResource qli = new RevSalesTrxn.RecordResource(QuoteLineItem.SObjectType, 'POST');
                Map<String, Object> fields = new Map<String, Object>{
                    'QuoteId' => '@{refQuote.id}',
                    'QuoteLineGroupId' => '@{refGroup' + g + '.id}',
                    'Product2Id' => entry.Product2Id,
                    'PricebookEntryId' => entry.Id,
                    'Quantity' => String.valueOf(line.quantity),
                    'UnitPrice' => String.valueOf(line.listPrice),
                    'StartDate' => plan.startDate,
                    'EndDate' => plan.endDate,
                    'BillingFrequency' => 'Monthly',
                    'PeriodBoundary' => 'Anniversary',
                    'RLM_HVAC_Site__c' => site.accountId,
                    'Description' => (line.units == null ? site.name : line.units).abbreviate(255)
                };
                if (line.discountPercent != null && line.discountPercent > 0) {
                    fields.put('Discount', String.valueOf(line.discountPercent));
                }
                qli.fieldValues = fields;
                records.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine' + n, qli));
            }
        }
        RevSalesTrxn.PlaceSalesTransactionResponse response = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
            new RevSalesTrxn.GraphRequest('hvacContractQuote', records),
            RevSalesTrxn.PricingPreferenceEnum.SYSTEM,
            RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
            new RevSalesTrxn.ConfigurationOptionsInput(),
            null,
            null,
            RevSalesTrxn.TaxPreferenceEnum.SKIP,
            null
        );
        if (response == null || response.isSuccess != true || String.isBlank(response.salesTransactionId)) {
            result.message = 'Place Sales Transaction failed: '
                + (response == null ? 'null' : JSON.serialize(response.errorResponse));
            return result;
        }
        result.quoteId = response.salesTransactionId;
        result.message = 'Contract quote created for ' + plan.sites.size() + ' sites and ' + plan.unitCount + ' units'
            + (plan.needsApproval ? '; the discount needs manager approval before it can be signed.' : '.');
        return result;
    }

    /** The facility director signs; falls back to any contact at the parent account. */
    private static Contact signerFor(Id accountId) {
        List<Contact> contacts = [
            SELECT Id, Name, Title FROM Contact WHERE AccountId = :accountId
            ORDER BY CreatedDate ASC
        ];
        for (Contact c : contacts) {
            if (c.Title != null && c.Title.containsIgnoreCase('Facilit')) {
                return c;
            }
        }
        return contacts.isEmpty() ? null : contacts[0];
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }
}
