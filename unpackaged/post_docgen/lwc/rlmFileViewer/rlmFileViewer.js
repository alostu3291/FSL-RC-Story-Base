import { LightningElement, api } from 'lwc';

const PAGE_RENDITION = '/sfc/servlet.shepherd/version/renditionDownload?rendition=SVGZ&versionId=';
const MAX_PAGES = 30;
const FIRST_PAGE_RETRIES = 4;
const RETRY_MS = 3000;

/**
 * Shows a file in place: images as-is, PDFs as page images. Navigation to filePreview isn't
 * supported in the Field Service mobile app, and relative /sfc URLs don't resolve there, so
 * every URL is built from the file's absolute VersionDataUrl.
 */
export default class RlmFileViewer extends LightningElement {
    /** ContentVersion.VersionDataUrl */
    @api url;
    @api versionId;
    @api fileType;
    @api title;

    pageCount = 1;
    lastPageFound = false;
    failed = false;
    attempt = 0;

    get isPdf() {
        return (this.fileType || '').toUpperCase() === 'PDF';
    }

    get pages() {
        const base = this.url ? this.url.substring(0, this.url.indexOf('/sfc/')) : '';
        const pages = [];
        for (let n = 0; n < this.pageCount; n++) {
            pages.push({
                key: `${n}-${this.attempt}`,
                index: n,
                src: `${base}${PAGE_RENDITION}${this.versionId}&page=${n}`,
                label: `Page ${n + 1}`
            });
        }
        return pages;
    }

    get loadingMore() {
        return this.isPdf && !this.failed && !this.lastPageFound;
    }

    pageLoaded(event) {
        const index = Number(event.target.dataset.index);
        if (index === this.pageCount - 1 && this.pageCount < MAX_PAGES) {
            this.pageCount += 1;
        } else if (index === this.pageCount - 1) {
            this.lastPageFound = true;
        }
    }

    pageMissing(event) {
        const index = Number(event.target.dataset.index);
        if (index > 0) {
            this.pageCount = index;
            this.lastPageFound = true;
            return;
        }
        // Renditions are generated after upload, so a brand-new PDF may not have one yet.
        if (this.attempt < FIRST_PAGE_RETRIES) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this.attempt += 1;
            }, RETRY_MS);
        } else {
            this.failed = true;
        }
    }

    imageMissing() {
        this.failed = true;
    }

    close() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}
