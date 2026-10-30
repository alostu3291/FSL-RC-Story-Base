import { LightningElement, api } from 'lwc';
import pageImage from '@salesforce/apex/RLM_SignAndPay.pageImage';

const MAX_PAGES = 30;
const FIRST_PAGE_RETRIES = 4;
const RETRY_MS = 3000;

function wait(ms) {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Base64 gzip-compressed JPEG to a data URL the img tag can show. */
async function toDataUrl(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
    }
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
    const jpeg = new Blob([await new Response(stream).arrayBuffer()], { type: 'image/jpeg' });
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(jpeg);
    });
}

/**
 * Shows a file in place: images from their absolute VersionDataUrl, PDFs as page images.
 * Navigation to filePreview isn't supported in the Field Service mobile app, relative /sfc URLs
 * don't resolve there, and its img loader can't read the gzip-encoded page renditions, so PDF
 * pages come through Apex and are decompressed here.
 */
export default class RlmFileViewer extends LightningElement {
    /** ContentVersion.VersionDataUrl */
    @api url;
    @api versionId;
    @api fileType;
    @api title;

    pages = [];
    loadingMore = false;
    failed = false;
    _closed = false;

    get isPdf() {
        return (this.fileType || '').toUpperCase() === 'PDF';
    }

    connectedCallback() {
        if (this.isPdf) {
            this.loadPages();
        }
    }

    disconnectedCallback() {
        this._closed = true;
    }

    async loadPages() {
        this.loadingMore = true;
        try {
            for (let n = 0; n < MAX_PAGES && !this._closed; n++) {
                let data = await pageImage({ versionId: this.versionId, page: n });
                // Renditions are generated after upload, so a brand-new PDF may not have one yet.
                for (let retry = 0; n === 0 && !data && retry < FIRST_PAGE_RETRIES && !this._closed; retry++) {
                    await wait(RETRY_MS);
                    data = await pageImage({ versionId: this.versionId, page: n });
                }
                if (!data) {
                    break;
                }
                const src = await toDataUrl(data);
                this.pages = [...this.pages, { key: n, src, label: `Page ${n + 1}` }];
            }
        } catch (e) {
            // show whatever pages loaded
        }
        this.loadingMore = false;
        this.failed = this.pages.length === 0;
    }

    imageMissing() {
        this.failed = true;
    }

    close() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}
