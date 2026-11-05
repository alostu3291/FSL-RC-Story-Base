import { LightningElement, api, wire } from 'lwc';
import siteSummary from '@salesforce/apex/RLM_HVAC_ContractInvoice.siteSummary';

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2 });
const day = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' });

/** A consolidated contract invoice by site: one subtotal per site, the PO number and the payment terms. */
export default class RlmHvacInvoiceSites extends LightningElement {
    @api recordId;
    summary;
    error;
    expanded = {};

    @wire(siteSummary, { invoiceId: '$recordId' })
    wired({ data, error }) {
        this.summary = data;
        this.error = error ? (error.body && error.body.message) || 'Could not load the invoice by site.' : undefined;
    }

    get show() {
        return this.summary && this.summary.isContract;
    }

    get header() {
        const s = this.summary;
        return `${s.sites.length} sites · ${money.format(s.total)}`;
    }

    get terms() {
        const s = this.summary;
        const parts = [];
        if (s.poNumber) parts.push(`PO ${s.poNumber}`);
        if (s.paymentTerm) parts.push(s.paymentTerm === 'Default Payment Term' ? 'Net 30' : s.paymentTerm);
        if (s.dueDate) parts.push(`due ${this.format(s.dueDate)}`);
        if (s.billTo) parts.push(`bill to ${s.billTo}`);
        return parts.join(' · ');
    }

    get sites() {
        return this.summary.sites.map((site, i) => {
            const key = site.accountId || `other-${i}`;
            const open = !!this.expanded[key];
            return {
                ...site,
                key,
                open,
                ariaExpanded: open ? 'true' : 'false',
                icon: open ? 'utility:chevrondown' : 'utility:chevronright',
                meta: [site.siteType, site.responseTier ? `${site.responseTier} response` : null].filter(Boolean).join(' · '),
                chargeLabel: money.format(site.charge),
                taxLabel: money.format(site.tax),
                totalLabel: money.format(site.total),
                lines: site.lines.map((l, j) => ({
                    ...l,
                    key: `${key}-${j}`,
                    period: l.startDate ? `${this.format(l.startDate)} – ${this.format(l.endDate)}` : '',
                    chargeLabel: money.format(l.charge)
                }))
            };
        });
    }

    get chargeLabel() {
        return money.format(this.summary.charge);
    }

    get taxLabel() {
        return money.format(this.summary.tax);
    }

    get totalLabel() {
        return money.format(this.summary.total);
    }

    format(value) {
        return value ? day.format(new Date(value)) : '';
    }

    toggle(event) {
        const key = event.currentTarget.dataset.key;
        this.expanded = { ...this.expanded, [key]: !this.expanded[key] };
    }
}
