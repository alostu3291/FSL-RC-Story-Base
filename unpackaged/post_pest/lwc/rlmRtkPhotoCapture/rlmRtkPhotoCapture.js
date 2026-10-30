import { LightningElement, api } from 'lwc';
import uploadPhoto from '@salesforce/apex/RLM_RTK_Inspection.uploadPhoto';

const MAX_EDGE = 1600;
const JPEG_QUALITY = 0.8;
// Apex request payloads cap out around 4 MB of base64.
const MAX_RAW_BYTES = 3 * 1024 * 1024;

function readAsDataUrl(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(file);
    });
}

function loadImage(src) {
    return new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => resolve(img);
        img.onerror = () => reject(new Error('This photo format could not be read on this device.'));
        img.src = src;
    });
}

/** Shrinks a camera photo to a JPEG the server can accept; falls back to the original if it can't decode it. */
async function toJpegBase64(file) {
    const original = await readAsDataUrl(file);
    try {
        const img = await loadImage(original);
        const scale = Math.min(1, MAX_EDGE / Math.max(img.naturalWidth, img.naturalHeight));
        const canvas = document.createElement('canvas');
        canvas.width = Math.round(img.naturalWidth * scale);
        canvas.height = Math.round(img.naturalHeight * scale);
        canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
        return { data: canvas.toDataURL('image/jpeg', JPEG_QUALITY).split(',')[1], extension: 'jpg' };
    } catch (e) {
        if (file.size > MAX_RAW_BYTES) {
            throw e;
        }
        return { data: original.split(',')[1], extension: (file.name.split('.').pop() || 'jpg').toLowerCase() };
    }
}

/**
 * Camera or library photo upload for a finding. Works in the Field Service mobile app,
 * where lightning-file-upload is not supported. Fires "uploaded" with the new document ids.
 */
export default class RlmRtkPhotoCapture extends LightningElement {
    @api recordId;
    @api stage = 'Before';
    @api label = 'Add photos';

    busy = false;
    progress = '';
    error;

    get buttonLabel() {
        return this.busy ? this.progress : this.label;
    }

    pick() {
        this.template.querySelector('input').click();
    }

    async handleFiles(event) {
        const files = Array.from(event.target.files || []);
        event.target.value = null;
        if (!files.length) return;
        this.busy = true;
        this.error = undefined;
        const documentIds = [];
        try {
            for (let i = 0; i < files.length; i++) {
                this.progress = files.length > 1 ? `Uploading ${i + 1} of ${files.length}…` : 'Uploading…';
                const { data, extension } = await toJpegBase64(files[i]);
                const base = (files[i].name || 'photo').replace(/\.[^.]+$/, '');
                documentIds.push(
                    await uploadPhoto({
                        findingId: this.recordId,
                        fileName: `${base}.${extension}`,
                        base64Data: data,
                        stage: this.stage
                    })
                );
            }
        } catch (e) {
            this.error = (e && e.body && e.body.message) || (e && e.message) || 'Upload failed';
        } finally {
            this.busy = false;
            if (documentIds.length) {
                this.dispatchEvent(new CustomEvent('uploaded', { detail: { documentIds } }));
            }
        }
    }
}
