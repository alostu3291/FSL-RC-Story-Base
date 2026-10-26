/**
 * Demo Sign &amp; Pay helpers: find the latest proposal PDF on a Quote and
 * stamp mock acceptance fields. Does not call a real payment processor.
 */
public with sharing class RLM_SignAndPay {
    public class ProposalDoc {
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public String title;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String fileType;
        @AuraEnabled public String url;
    }

    public class QuoteContext {
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String accountName;
        @AuraEnabled public Decimal grandTotal;
        @AuraEnabled public String currencyIsoCode;
        @AuraEnabled public ProposalDoc proposal;
        @AuraEnabled public Boolean alreadySigned;
        @AuraEnabled public String signedBy;
        @AuraEnabled public Datetime signedAt;
        @AuraEnabled public String cardLast4;
        @AuraEnabled public String cardBrand;
    }

    public class AcceptRequest {
        @InvocableVariable(required=true) public Id quoteId;
        @InvocableVariable(required=true) public Id contentDocumentId;
        @InvocableVariable(required=true) public String signerName;
        @InvocableVariable public String cardLast4;
        @InvocableVariable public String cardBrand;
    }

    public class AcceptResponse {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
    }

    @AuraEnabled
    public static QuoteContext loadContext(Id quoteId, Id contentDocumentId) {
        if (quoteId == null) {
            throw new AuraHandledException('Quote Id is required.');
        }
        Quote quoteRecord = [
            SELECT Id, QuoteNumber, GrandTotal, CurrencyIsoCode, QuoteAccount.Name,
                RLM_Demo_Signed_By__c, RLM_Demo_Signed_At__c,
                RLM_Demo_Signed_Document_Id__c, RLM_Demo_Card_Last4__c, RLM_Demo_Card_Brand__c
            FROM Quote
            WHERE Id = :quoteId
            LIMIT 1
        ];
        QuoteContext ctx = new QuoteContext();
        ctx.quoteId = quoteRecord.Id;
        ctx.quoteNumber = quoteRecord.QuoteNumber;
        ctx.accountName = quoteRecord.QuoteAccount != null ? quoteRecord.QuoteAccount.Name : null;
        ctx.grandTotal = quoteRecord.GrandTotal;
        ctx.currencyIsoCode = quoteRecord.CurrencyIsoCode;
        ctx.alreadySigned = quoteRecord.RLM_Demo_Signed_At__c != null;
        ctx.signedBy = quoteRecord.RLM_Demo_Signed_By__c;
        ctx.signedAt = quoteRecord.RLM_Demo_Signed_At__c;
        ctx.cardLast4 = quoteRecord.RLM_Demo_Card_Last4__c;
        ctx.cardBrand = quoteRecord.RLM_Demo_Card_Brand__c;

        if (contentDocumentId != null) {
            ctx.proposal = describeDocument(contentDocumentId);
        } else {
            ctx.proposal = findLatestProposal(quoteId);
        }
        return ctx;
    }

    @AuraEnabled(cacheable=true)
    public static ProposalDoc findLatestProposal(Id quoteId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileType,
                ContentDocument.LatestPublishedVersionId, ContentDocument.CreatedDate,
                ContentDocument.LatestPublishedVersion.VersionDataUrl
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :quoteId
            ORDER BY ContentDocument.CreatedDate DESC
            LIMIT 25
        ];
        ProposalDoc best = null;
        for (ContentDocumentLink link : links) {
            String title = link.ContentDocument.Title != null ? link.ContentDocument.Title.toLowerCase() : '';
            String fileType = link.ContentDocument.FileType != null ? link.ContentDocument.FileType.toUpperCase() : '';
            Boolean looksLikeProposal =
                title.contains('proposal') ||
                title.contains('quote') ||
                fileType == 'PDF';
            if (!looksLikeProposal) {
                continue;
            }
            ProposalDoc doc = new ProposalDoc();
            doc.contentDocumentId = link.ContentDocumentId;
            doc.contentVersionId = link.ContentDocument.LatestPublishedVersionId;
            doc.title = link.ContentDocument.Title;
            doc.createdDate = link.ContentDocument.CreatedDate;
            doc.fileType = link.ContentDocument.FileType;
            doc.url = link.ContentDocument.LatestPublishedVersion.VersionDataUrl;
            if (title.contains('proposal')) {
                return doc;
            }
            if (best == null) {
                best = doc;
            }
        }
        return best;
    }

    /**
     * One page of a document as a base64, gzip-compressed JPEG, or null past the last page.
     * The page rendition is always served gzip-encoded, which the Field Service mobile app
     * can't load in an img tag, so the viewer fetches it here and decompresses it itself.
     */
    @AuraEnabled
    public static String pageImage(Id versionId, Integer page) {
        if (versionId == null || page == null || page < 0
                || [SELECT COUNT() FROM ContentVersion WHERE Id = :versionId] == 0) {
            return null;
        }
        PageReference rendition = new PageReference('/sfc/servlet.shepherd/version/renditionDownload');
        rendition.getParameters().putAll(new Map<String, String>{
            'rendition' => 'SVGZ', 'versionId' => versionId, 'page' => String.valueOf(page)
        });
        Blob content = Test.isRunningTest() ? Blob.valueOf('{"error":"test"}') : rendition.getContent();
        String encoded = EncodingUtil.base64Encode(content);
        // Gzip data starts 1f 8b 08, which is "H4sI" in base64; anything else is an error page.
        return encoded.startsWith('H4sI') ? encoded : null;
    }

    @AuraEnabled
    public static AcceptResponse accept(Id quoteId, Id contentDocumentId, String signerName, String cardLast4, String cardBrand) {
        AcceptRequest req = new AcceptRequest();
        req.quoteId = quoteId;
        req.contentDocumentId = contentDocumentId;
        req.signerName = signerName;
        req.cardLast4 = cardLast4;
        req.cardBrand = cardBrand;
        return acceptInvocable(new List<AcceptRequest>{ req })[0];
    }

    @InvocableMethod(label='Record Demo Sign & Pay' category='Document Generation'
        description='Stamps mock Sign & Pay acceptance fields on the Quote. Demo only.')
    public static List<AcceptResponse> acceptInvocable(List<AcceptRequest> requests) {
        List<AcceptResponse> responses = new List<AcceptResponse>();
        for (AcceptRequest req : requests) {
            AcceptResponse res = new AcceptResponse();
            try {
                if (req.quoteId == null || req.contentDocumentId == null || String.isBlank(req.signerName)) {
                    res.success = false;
                    res.message = 'Quote, document, and signer name are required.';
                    responses.add(res);
                    continue;
                }
                String last4 = req.cardLast4 == null ? '' : req.cardLast4.replaceAll('[^0-9]', '');
                if (last4.length() > 4) {
                    last4 = last4.substring(last4.length() - 4);
                }
                Quote quoteRecord = new Quote(
                    Id = req.quoteId,
                    RLM_Demo_Signed_By__c = req.signerName.trim(),
                    RLM_Demo_Signed_At__c = System.now(),
                    RLM_Demo_Card_Last4__c = last4,
                    RLM_Demo_Card_Brand__c = String.isBlank(req.cardBrand) ? 'Card' : req.cardBrand.trim(),
                    RLM_Demo_Signed_Document_Id__c = String.valueOf(req.contentDocumentId)
                );
                // Prefer Approved when the org allows it; ignore status errors for demo.
                try {
                    quoteRecord.Status = 'Approved';
                    update quoteRecord;
                } catch (DmlException statusEx) {
                    quoteRecord.Status = null;
                    update quoteRecord;
                }
                res.success = true;
                res.message = 'Signed and card on file (demo). Proposal linked.';
            } catch (Exception ex) {
                res.success = false;
                res.message = ex.getMessage();
            }
            responses.add(res);
        }
        return responses;
    }

    private static ProposalDoc describeDocument(Id contentDocumentId) {
        ContentDocument doc = [
            SELECT Id, Title, FileType, LatestPublishedVersionId, CreatedDate,
                LatestPublishedVersion.VersionDataUrl
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            LIMIT 1
        ];
        ProposalDoc result = new ProposalDoc();
        result.contentDocumentId = doc.Id;
        result.contentVersionId = doc.LatestPublishedVersionId;
        result.title = doc.Title;
        result.createdDate = doc.CreatedDate;
        result.fileType = doc.FileType;
        result.url = doc.LatestPublishedVersion.VersionDataUrl;
        return result;
    }
}
