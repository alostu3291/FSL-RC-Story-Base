/**
 * Brightline Commercial documents, generated with DocGen and attached to the record:
 *  - a contract quote gets the planned maintenance proposal, priced site by site (RLM_HVAC_Contract_Proposal);
 *  - a capital project quote gets the project proposal with its 40/40/20 milestone schedule (RLM_HVAC_Project_Proposal);
 *  - a contract or project invoice gets the consolidated invoice with a subtotal per site (RLM_HVAC_Commercial_Invoice).
 */
public with sharing class RLM_HVAC_CommercialDocuments {

    public static final String CONTRACT_PROPOSAL = 'RLM_HVAC_Contract_Proposal';
    public static final String PROJECT_PROPOSAL = 'RLM_HVAC_Project_Proposal';
    public static final String CONSOLIDATED_INVOICE = 'RLM_HVAC_Commercial_Invoice';
    public static final String PROJECT_SKU = 'HVAC-COM-RTU-REPL';
    @TestVisible private static String projectSku = PROJECT_SKU;

    public class DocumentException extends Exception {}

    public class Status {
        @AuraEnabled public String status;
        @AuraEnabled public String kind;
        @AuraEnabled public String processId;
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String title;
        @AuraEnabled public String message;
    }

    private class Target {
        String template;
        String kind;
        String title;
    }

    /** The newest document already attached to the record, or status None. */
    @AuraEnabled
    public static Status latest(Id recordId) {
        try {
            return latestFor(recordId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static Status create(Id recordId) {
        try {
            return createFor(recordId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static Status check(Id processId, Id recordId) {
        try {
            return checkFor(processId, recordId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static Status latestFor(Id recordId) {
        Target t = target(recordId);
        Status s = new Status();
        s.kind = t.kind;
        s.status = 'None';
        String prefix = t.title + '%';
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, ContentDocument.Title FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId AND ContentDocument.Title LIKE :prefix
                AND ContentDocument.FileType = 'PDF'
            ORDER BY ContentDocument.CreatedDate DESC LIMIT 1
        ]) {
            s.status = 'Ready';
            s.contentDocumentId = link.ContentDocumentId;
            s.title = link.ContentDocument.Title;
        }
        return s;
    }

    public static Status createFor(Id recordId) {
        Target t = target(recordId);
        if (t.template == CONSOLIDATED_INVOICE) {
            RLM_HVAC_ContractInvoice.stampSites(new Set<Id>{ recordId });
        }
        List<DocumentTemplate> templates = [
            SELECT Id FROM DocumentTemplate
            WHERE Name = :t.template AND IsActive = true
            ORDER BY VersionNumber DESC LIMIT 1
        ];
        if (templates.isEmpty()) {
            throw new DocumentException('The Brightline ' + t.kind + ' template (' + t.template + ') is not active in this org.');
        }
        DocumentGenerationProcess process = new DocumentGenerationProcess(
            Type = 'GenerateAndConvert',
            ReferenceObject = recordId,
            DocumentTemplateId = templates[0].Id,
            RequestText = JSON.serialize(new Map<String, Object>{ 'keepIntermediate' => false, 'title' => t.title }),
            DocGenApiVersionType = 'Advanced',
            DocumentInputType = 'DocumentTemplate',
            DataRaptorInput = JSON.serialize(new Map<String, Object>{ 'Id' => recordId })
        );
        insert process;
        Status s = new Status();
        s.kind = t.kind;
        s.processId = process.Id;
        s.status = 'Generating';
        return s;
    }

    /** Checks a generation request; once it is done, makes sure the PDF is attached to the record. */
    public static Status checkFor(Id processId, Id recordId) {
        DocumentGenerationProcess process = [
            SELECT Id, Status, ResponseText FROM DocumentGenerationProcess WHERE Id = :processId
        ];
        Status s = new Status();
        s.kind = target(recordId).kind;
        s.processId = process.Id;
        if (process.Status == 'Failure') {
            s.status = 'Failed';
            s.message = String.isBlank(process.ResponseText) ? 'Document generation failed.' : process.ResponseText;
            return s;
        }
        if (process.Status != 'Success') {
            s.status = 'Generating';
            return s;
        }
        List<Id> versionIds = new List<Id>();
        for (String token : (process.ResponseText ?? '').split(',')) {
            try {
                versionIds.add(Id.valueOf(token.trim()));
            } catch (Exception notAnId) {
                continue;
            }
        }
        List<ContentVersion> pdfs = [
            SELECT ContentDocumentId, Title FROM ContentVersion
            WHERE Id IN :versionIds AND FileType = 'PDF' LIMIT 1
        ];
        if (pdfs.isEmpty()) {
            s.status = 'Failed';
            s.message = 'The document finished without a PDF.';
            return s;
        }
        if ([SELECT COUNT() FROM ContentDocumentLink
             WHERE LinkedEntityId = :recordId AND ContentDocumentId = :pdfs[0].ContentDocumentId] == 0) {
            insert new ContentDocumentLink(
                LinkedEntityId = recordId, ContentDocumentId = pdfs[0].ContentDocumentId, ShareType = 'V');
        }
        s.status = 'Ready';
        s.contentDocumentId = pdfs[0].ContentDocumentId;
        s.title = pdfs[0].Title;
        return s;
    }

    private static Target target(Id recordId) {
        Target t = new Target();
        if (recordId.getSObjectType() == Invoice.SObjectType) {
            Invoice inv = [SELECT DocumentNumber FROM Invoice WHERE Id = :recordId];
            t.template = CONSOLIDATED_INVOICE;
            t.kind = 'invoice';
            t.title = 'Brightline Invoice ' + inv.DocumentNumber;
            return t;
        }
        if (recordId.getSObjectType() != Quote.SObjectType) {
            throw new DocumentException('Brightline Commercial documents are created from a quote or an invoice.');
        }
        Quote q = [
            SELECT QuoteNumber,
                (SELECT Product2.StockKeepingUnit, RLM_HVAC_Site__c FROM QuoteLineItems)
            FROM Quote WHERE Id = :recordId
        ];
        Boolean project = false;
        Boolean sites = false;
        for (QuoteLineItem line : q.QuoteLineItems) {
            project |= line.Product2?.StockKeepingUnit == projectSku;
            sites |= line.RLM_HVAC_Site__c != null;
        }
        if (project) {
            t.template = PROJECT_PROPOSAL;
            t.kind = 'project proposal';
            t.title = 'Brightline Project Proposal ' + q.QuoteNumber;
        } else if (sites) {
            t.template = CONTRACT_PROPOSAL;
            t.kind = 'contract proposal';
            t.title = 'Brightline Contract Proposal ' + q.QuoteNumber;
        } else {
            throw new DocumentException('This quote has no Brightline Commercial sites.');
        }
        return t;
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }
}
