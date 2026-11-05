/**
 * Renews a property group's Brightline Commercial contract for another 12 months with the annual
 * increase (RLM_HVAC_CommercialPricing.RENEWAL_UPLIFT). initiateRenewal creates the renewal quote
 * from the contract assets, one line per asset starting the day after the contract ends; Place Sales
 * Transaction then sets each line's renewal price (this year's net price plus the increase), puts
 * the lines back in a line group per site with their site, and fills in the contract header (line
 * of business, Net 30, 12-month term, the facility director). The renewal quote is booked like the
 * first contract, with the next year's PO (Book Contract).
 */
public with sharing class RLM_HVAC_ContractRenew {

    public class Site {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal currentMonthly = 0;
        @AuraEnabled public Decimal renewalMonthly = 0;
    }

    public class State {
        @AuraEnabled public Id groupId;
        @AuraEnabled public String groupName;
        @AuraEnabled public Boolean hasContract = false;
        @AuraEnabled public Date contractEnd;
        @AuraEnabled public Date renewalStart;
        @AuraEnabled public Date renewalEnd;
        @AuraEnabled public Decimal upliftPercent = RLM_HVAC_CommercialPricing.RENEWAL_UPLIFT;
        @AuraEnabled public Decimal currentMonthly = 0;
        @AuraEnabled public Decimal renewalMonthly = 0;
        @AuraEnabled public Decimal renewalAnnual = 0;
        @AuraEnabled public List<Site> sites = new List<Site>();
        @AuraEnabled public Id renewalQuoteId;
        @AuraEnabled public String renewalQuoteName;
    }

    /** A contract asset and the order product it came from, which has its price and site. */
    @TestVisible
    private class Holding {
        Id assetId;
        Id siteId;
        String siteName;
        String sku;
        String units;
        Decimal quantity;
        Decimal netUnitPrice;
        Date endDate;
    }

    @AuraEnabled
    public static State state(Id recordId) {
        try {
            return stateFor(recordId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static State renew(Id recordId) {
        try {
            return renewFor(recordId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static State renewFor(Id recordId) {
        State s = stateFor(recordId);
        if (!s.hasContract) {
            throw new RenewException(s.groupName + ' has no active contract to renew.');
        }
        if (s.renewalQuoteId != null) {
            throw new RenewException('Renewal quote ' + s.renewalQuoteName + ' is already open.');
        }
        Map<Id, Holding> holdings = holdingsFor(s.groupId);
        Id quoteId = initiate(holdings.keySet(), s.renewalStart, s.renewalEnd);
        reprice(quoteId, s, holdings);
        return stateFor(recordId);
    }

    public static State stateFor(Id recordId) {
        Account record = [SELECT Id, ParentId FROM Account WHERE Id = :recordId];
        Account grp = [SELECT Id, Name FROM Account WHERE Id = :(record.ParentId != null ? record.ParentId : record.Id)];
        State s = new State();
        s.groupId = grp.Id;
        s.groupName = grp.Name;
        Map<Id, Holding> holdings = holdingsFor(grp.Id);
        if (holdings.isEmpty()) {
            return s;
        }
        s.hasContract = true;
        Map<Id, Site> bySite = new Map<Id, Site>();
        for (Holding h : holdings.values()) {
            if (h.endDate != null && (s.contractEnd == null || h.endDate > s.contractEnd)) {
                s.contractEnd = h.endDate;
            }
            Site site = bySite.get(h.siteId);
            if (site == null) {
                site = new Site();
                site.accountId = h.siteId;
                site.name = h.siteName;
                bySite.put(h.siteId, site);
            }
            Decimal current = h.netUnitPrice * h.quantity;
            Decimal renewal = renewalPrice(h.netUnitPrice) * h.quantity;
            site.currentMonthly += current;
            site.renewalMonthly += renewal;
            s.currentMonthly += current;
            s.renewalMonthly += renewal;
        }
        s.renewalStart = s.contractEnd.addDays(1);
        s.renewalEnd = s.renewalStart.addMonths(RLM_HVAC_CommercialPricing.TERM_MONTHS).addDays(-1);
        s.renewalAnnual = s.renewalMonthly * RLM_HVAC_CommercialPricing.TERM_MONTHS;
        List<String> names = new List<String>();
        Map<String, Site> byName = new Map<String, Site>();
        for (Site site : bySite.values()) {
            names.add(site.name);
            byName.put(site.name, site);
        }
        names.sort();
        for (String n : names) {
            s.sites.add(byName.get(n));
        }
        for (Quote q : [
            SELECT Id, Name FROM Quote
            WHERE QuoteAccountId = :grp.Id AND RLM_Line_of_Business__c = :RLM_HVAC_CommercialPricing.LOB
                AND Id IN (SELECT QuoteId FROM QuoteAction WHERE Type = 'Renew')
                AND Status NOT IN ('Accepted', 'Rejected', 'Denied')
            ORDER BY CreatedDate DESC LIMIT 1
        ]) {
            s.renewalQuoteId = q.Id;
            s.renewalQuoteName = q.Name;
        }
        return s;
    }

    /** This year's net price plus the annual increase, to the cent. */
    @TestVisible
    private static Decimal renewalPrice(Decimal netUnitPrice) {
        return RLM_HVAC_CommercialPricing.renewalPrice(netUnitPrice);
    }

    /** The group's running contract assets with their price, quantity and site from the order products. */
    private static Map<Id, Holding> holdingsFor(Id groupId) {
        Map<Id, Asset> assets = new Map<Id, Asset>([
            SELECT Id, RLM_HVAC_Site__c, RLM_HVAC_Site__r.Name, Product2.StockKeepingUnit, LifecycleEndDate
            FROM Asset
            WHERE AccountId = :groupId AND RLM_HVAC_Site__c != null AND Product2.StockKeepingUnit LIKE 'HVAC-COM-%'
                AND LifecycleEndDate >= :Datetime.now()
        ]);
        List<AssetActionSource> sources = new List<AssetActionSource>();
        Set<Id> itemIds = new Set<Id>();
        for (AssetActionSource source : [
            SELECT AssetAction.AssetId, ReferenceEntityItemId FROM AssetActionSource
            WHERE AssetAction.AssetId IN :assets.keySet() AND ReferenceEntityItemId != null
            ORDER BY AssetAction.ActionDate ASC, CreatedDate ASC
        ]) {
            if (source.ReferenceEntityItemId.getSobjectType() == OrderItem.SObjectType) {
                sources.add(source);
                itemIds.add(source.ReferenceEntityItemId);
            }
        }
        Map<Id, OrderItem> items = new Map<Id, OrderItem>([
            SELECT Id, Quantity, UnitPrice, NetUnitPrice, Description FROM OrderItem WHERE Id IN :itemIds
        ]);
        // An amendment that anchors on an asset adds a zero-quantity line to it, so the price comes
        // from the latest order product that sold a quantity.
        Map<Id, OrderItem> itemByAsset = new Map<Id, OrderItem>();
        for (AssetActionSource source : sources) {
            OrderItem item = items.get(source.ReferenceEntityItemId);
            if (item != null && item.Quantity != null && item.Quantity > 0) {
                itemByAsset.put(source.AssetAction.AssetId, item);
            }
        }
        Map<Id, Holding> holdings = new Map<Id, Holding>();
        for (Asset a : assets.values()) {
            OrderItem item = itemByAsset.get(a.Id);
            if (item == null) {
                continue;
            }
            Holding h = new Holding();
            h.assetId = a.Id;
            h.siteId = a.RLM_HVAC_Site__c;
            h.siteName = a.RLM_HVAC_Site__r.Name;
            h.sku = a.Product2.StockKeepingUnit;
            h.units = item.Description;
            h.quantity = item.Quantity;
            h.netUnitPrice = item.NetUnitPrice ?? item.UnitPrice;
            h.endDate = a.LifecycleEndDate.dateGmt();
            holdings.put(a.Id, h);
        }
        return holdings;
    }

    private static Id initiate(Set<Id> assetIds, Date startDate, Date endDate) {
        List<String> ids = new List<String>();
        for (Id assetId : assetIds) {
            ids.add(String.valueOf(assetId));
        }
        Invocable.Action action = Invocable.Action.createStandardAction('initiateRenewal');
        action.setInvocationParameter('renewAssetIds', ids);
        action.setInvocationParameter('renewOutputType', 'Quote');
        action.setInvocationParameter('renewStartDate', gmt(startDate));
        action.setInvocationParameter('renewEndDate', gmt(endDate));
        Invocable.Action.Result result = action.invoke()[0];
        if (!result.isSuccess()) {
            throw new RenewException('Renewal failed: ' + result.getErrors()[0].getMessage());
        }
        return (Id) result.getOutputParameters().get('renewRecordId');
    }

    private static String gmt(Date d) {
        return Datetime.newInstanceGmt(d.year(), d.month(), d.day()).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss');
    }

    private static void reprice(Id quoteId, State s, Map<Id, Holding> holdings) {
        Contact signer;
        for (Contact c : [SELECT Id, Title FROM Contact WHERE AccountId = :s.groupId ORDER BY CreatedDate]) {
            if (signer == null && c.Title != null && c.Title.containsIgnoreCase('Facilit')) {
                signer = c;
            }
        }
        RevSalesTrxn.RecordResource quote = new RevSalesTrxn.RecordResource(Quote.SObjectType, 'PATCH', quoteId);
        quote.fieldValues = new Map<String, Object>{
            'Name' => (s.groupName + ' - Planned Maintenance Contract Renewal ' + s.renewalStart.year()).left(255),
            'RLM_Line_of_Business__c' => RLM_HVAC_CommercialPricing.LOB,
            'RLM_Payment_Terms__c' => RLM_HVAC_CommercialPricing.PAYMENT_TERMS,
            'RLM_TermMonths__c' => String.valueOf(RLM_HVAC_CommercialPricing.TERM_MONTHS),
            'ExpirationDate' => String.valueOf(s.contractEnd)
        };
        if (signer != null) {
            quote.fieldValues.put('ContactId', signer.Id);
        }
        List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>{
            new RevSalesTrxn.RecordWithReferenceRequest('refQuote', quote)
        };
        Map<Id, String> groupRefBySite = new Map<Id, String>();
        Integer g = 0;
        for (Site site : s.sites) {
            g++;
            RevSalesTrxn.RecordResource grp = new RevSalesTrxn.RecordResource(QuoteLineGroup.SObjectType, 'POST');
            grp.fieldValues = new Map<String, Object>{
                'QuoteId' => quoteId, 'Name' => site.name, 'SortOrder' => String.valueOf(g),
                'Description' => ('Renewal with a ' + s.upliftPercent.stripTrailingZeros().toPlainString() + '% increase').abbreviate(255)
            };
            groupRefBySite.put(site.accountId, 'refGroup' + g);
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refGroup' + g, grp));
        }
        Integer n = 0;
        for (QuoteLineItem line : [
            SELECT Id, QuoteAction.SourceAssetId FROM QuoteLineItem WHERE QuoteId = :quoteId
        ]) {
            Holding h = holdings.get(line.QuoteAction?.SourceAssetId);
            if (h == null) {
                continue;
            }
            n++;
            RevSalesTrxn.RecordResource qli = new RevSalesTrxn.RecordResource(QuoteLineItem.SObjectType, 'PATCH', line.Id);
            qli.fieldValues = new Map<String, Object>{
                'UnitPrice' => String.valueOf(renewalPrice(h.netUnitPrice)),
                'QuoteLineGroupId' => '@{' + groupRefBySite.get(h.siteId) + '.id}',
                'RLM_HVAC_Site__c' => h.siteId,
                'BillingFrequency' => 'Monthly'
            };
            if (String.isNotBlank(h.units)) {
                qli.fieldValues.put('Description', h.units);
            }
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine' + n, qli));
        }
        RevSalesTrxn.PlaceSalesTransactionResponse response = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
            new RevSalesTrxn.GraphRequest('hvacRenewal', records),
            RevSalesTrxn.PricingPreferenceEnum.SYSTEM, RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
            new RevSalesTrxn.ConfigurationOptionsInput(), null, null, RevSalesTrxn.TaxPreferenceEnum.SKIP, null);
        if (response == null || response.isSuccess != true) {
            throw new RenewException('Place Sales Transaction failed: '
                + (response == null ? 'null' : JSON.serialize(response.errorResponse)));
        }
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    public class RenewException extends Exception {}
}
