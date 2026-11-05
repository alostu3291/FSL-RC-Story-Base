@IsTest
private class RLM_HVAC_SiteInvoiceExplainerTest {

    private static RLM_HVAC_SiteInvoiceExplainer.Response ask(Id recordId, String accountName, String siteName) {
        RLM_HVAC_SiteInvoiceExplainer.Request r = new RLM_HVAC_SiteInvoiceExplainer.Request();
        r.recordId = recordId;
        r.accountName = accountName;
        r.siteName = siteName;
        return RLM_HVAC_SiteInvoiceExplainer.explain(new List<RLM_HVAC_SiteInvoiceExplainer.Request>{ r })[0];
    }

    @IsTest
    static void anUnknownGroupAsksForTheName() {
        RLM_HVAC_SiteInvoiceExplainer.Response r = ask(null, 'Nobody Property Group', null);

        Assert.isTrue(r.explanation.contains('couldn\'t find'), r.explanation);
        Assert.isNull(r.invoiceNumbers);
    }

    @IsTest
    static void aGroupWithoutInvoicesSaysSo() {
        Account parent = new Account(Name = 'Explainer Test Group', RLM_HVAC_Site_Type__c = 'Headquarters');
        insert parent;
        Account site = new Account(Name = 'Explainer Test Bistro', ParentId = parent.Id, RLM_HVAC_Site_Type__c = 'Restaurant');
        insert site;

        Assert.isTrue(ask(parent.Id, null, null).explanation.contains('no posted'), 'from the group record');
        Assert.isTrue(ask(site.Id, null, null).explanation.contains('no posted'), 'a site resolves to its group');
        Assert.isTrue(ask(null, null, 'Explainer Test Bistro').explanation.contains('no posted'), 'by site name');
    }

    @IsTest
    static void amountsAreFormattedForTheAgent() {
        Assert.areEqual('$4,551.13', RLM_HVAC_SiteInvoiceExplainer.money(4551.13));
        Assert.areEqual('$103,400.00', RLM_HVAC_SiteInvoiceExplainer.money(103400));
        Assert.areEqual('$0.50', RLM_HVAC_SiteInvoiceExplainer.money(0.5));
        Assert.areEqual('-$12.00', RLM_HVAC_SiteInvoiceExplainer.money(-12));
        Assert.areEqual('40%', RLM_HVAC_SiteInvoiceExplainer.percent(41360, 103400));
        Assert.areEqual('11.9%', RLM_HVAC_SiteInvoiceExplainer.percent(540.50, 4551.13));
    }
}
