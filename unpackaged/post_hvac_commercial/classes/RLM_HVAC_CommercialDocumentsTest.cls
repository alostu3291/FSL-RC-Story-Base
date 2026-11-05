@IsTest
private class RLM_HVAC_CommercialDocumentsTest {

    private static Quote quoteWith(String sku, Boolean onSite) {
        Account parent = new Account(Name = 'Docs Test Group', RLM_HVAC_Site_Type__c = 'Headquarters');
        insert parent;
        Account office = new Account(Name = 'Docs Test Office', ParentId = parent.Id, RLM_HVAC_Site_Type__c = 'Office');
        insert office;
        Product2 product = new Product2(Name = sku, StockKeepingUnit = sku, IsActive = true);
        insert product;
        PricebookEntry entry = new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = product.Id,
            UnitPrice = 100, IsActive = true);
        insert entry;
        Opportunity o = new Opportunity(Name = 'Docs', StageName = 'Prospecting', CloseDate = Date.today(), AccountId = parent.Id);
        insert o;
        Quote q = new Quote(Name = 'Docs Quote', OpportunityId = o.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert q;
        insert new QuoteLineItem(QuoteId = q.Id, PricebookEntryId = entry.Id, Product2Id = product.Id, Quantity = 1,
            UnitPrice = 100, RLM_HVAC_Site__c = onSite ? office.Id : null);
        return [SELECT Id, QuoteNumber FROM Quote WHERE Id = :q.Id];
    }

    private static void assertCreateNeedsTheTemplate(Id recordId, String template) {
        try {
            RLM_HVAC_CommercialDocuments.Status s = RLM_HVAC_CommercialDocuments.createFor(recordId);
            Assert.areEqual('Generating', s.status);
            Assert.isNotNull(s.processId);
        } catch (RLM_HVAC_CommercialDocuments.DocumentException e) {
            Assert.isTrue(e.getMessage().contains(template), e.getMessage());
        }
    }

    @IsTest
    static void aContractQuoteGetsTheContractProposal() {
        Quote q = quoteWith('TEST-DOCS-PM', true);

        RLM_HVAC_CommercialDocuments.Status s = RLM_HVAC_CommercialDocuments.latestFor(q.Id);

        Assert.areEqual('None', s.status);
        Assert.areEqual('contract proposal', s.kind);
        assertCreateNeedsTheTemplate(q.Id, RLM_HVAC_CommercialDocuments.CONTRACT_PROPOSAL);
    }

    @IsTest
    static void aProjectQuoteGetsTheProjectProposal() {
        RLM_HVAC_CommercialDocuments.projectSku = 'TEST-DOCS-RTU';
        Quote q = quoteWith('TEST-DOCS-RTU', true);

        RLM_HVAC_CommercialDocuments.Status s = RLM_HVAC_CommercialDocuments.latestFor(q.Id);

        Assert.areEqual('project proposal', s.kind);
        assertCreateNeedsTheTemplate(q.Id, RLM_HVAC_CommercialDocuments.PROJECT_PROPOSAL);
    }

    @IsTest
    static void theAttachedProposalIsFound() {
        Quote q = quoteWith('TEST-DOCS-PM', true);
        insert new ContentVersion(Title = 'Brightline Contract Proposal ' + q.QuoteNumber, PathOnClient = 'proposal.pdf',
            VersionData = Blob.valueOf('%PDF-1.4'), FirstPublishLocationId = q.Id);

        RLM_HVAC_CommercialDocuments.Status s = RLM_HVAC_CommercialDocuments.latest(q.Id);

        Assert.areEqual('Ready', s.status);
        Assert.isNotNull(s.contentDocumentId);
    }

    @IsTest
    static void onlyCommercialQuotesAndInvoicesGetDocuments() {
        Quote home = quoteWith('TEST-DOCS-HOME', false);
        try {
            RLM_HVAC_CommercialDocuments.latest(home.Id);
            Assert.fail('a quote without sites is not commercial');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('no Brightline Commercial sites'), e.getMessage());
        }
        Account a = [SELECT Id FROM Account LIMIT 1];
        try {
            RLM_HVAC_CommercialDocuments.create(a.Id);
            Assert.fail('accounts have no document');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('quote or an invoice'), e.getMessage());
        }
    }

    @IsTest
    static void stampingInvoicesWithoutSitesWritesNothing() {
        RLM_HVAC_ContractInvoice.stampSites(new Set<Id>());

        Assert.areEqual(0, [SELECT COUNT() FROM RLM_HVAC_Invoice_Site__c]);
        Assert.isTrue(RLM_HVAC_ContractInvoice.summariesFor(new Set<Id>()).isEmpty());
    }
}
