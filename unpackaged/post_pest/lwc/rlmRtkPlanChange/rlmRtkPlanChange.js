import { LightningElement, api } from 'lwc';
import getState from '@salesforce/apex/RLM_RTK_PlanChange.getState';
import applyChange from '@salesforce/apex/RLM_RTK_PlanChange.applyChange';

const money = (value) =>
    new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(value || 0);

const monthly = (value) => `${value < 0 ? '−' : '+'}${money(Math.abs(value))}/mo`;

const day = (value) =>
    value
        ? new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(value))
        : '';

/**
 * Plan changes from the field: the technician picks a new plan tier, or adds or removes a Termite or
 * Mosquito plan, and the customer approves the change on the device. The change amends the
 * customer's plan from tomorrow and is billed right away.
 */
export default class RlmRtkPlanChange extends LightningElement {
    @api recordId;
    state;
    open = false;
    busy = false;
    error;
    selectedSku;
    approver = '';

    connectedCallback() {
        this.load();
    }

    async load() {
        try {
            this.apply(await getState({ recordId: this.recordId }));
        } catch (e) {
            this.error = this.message(e);
        }
    }

    apply(state) {
        this.state = state;
        if (!this.approver) this.approver = state.customerName || '';
        if (!this.allPlans.some((p) => p.sku === this.selectedSku && !p.current)) {
            this.selectedSku = undefined;
        }
    }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong';
    }

    get allPlans() {
        return this.state ? [...this.state.tiers, ...this.state.addOnPlans] : [];
    }

    // ---------- panel ----------
    toggle() {
        this.open = !this.open;
        this.error = undefined;
    }
    get toggleLabel() {
        return this.open ? 'Hide' : 'Change plan';
    }
    get isLoading() {
        return !this.state && !this.error;
    }
    get summary() {
        if (!this.state) return 'Upgrade, downgrade or add a plan.';
        if (!this.state.hasPlans) return 'No active plan yet. Use Inspect & Quote to start one.';
        const plan = this.state.currentPlanName || 'Current plans';
        return `${plan} · ${money(this.state.monthlyTotal)}/mo`;
    }
    get hasScheduled() {
        return this.state && this.state.scheduled.length > 0;
    }
    get scheduledView() {
        return (this.state ? this.state.scheduled : []).map((s) => ({
            ...s,
            meta: `Order ${s.orderNumber} · starts ${day(s.startDate)}`
        }));
    }
    get canChange() {
        return this.state && this.state.hasPlans && !this.state.lockedReason;
    }
    get lockedReason() {
        return this.state && this.state.hasPlans ? this.state.lockedReason : null;
    }

    // ---------- choose ----------
    view(plans) {
        return plans.map((p) => {
            const on = p.sku === this.selectedSku;
            const removing = on && p.change === 'Remove';
            let badge = null;
            let badgeCls = 'badge';
            if (removing) {
                badge = 'Remove';
                badgeCls = 'badge remove';
            } else if (p.current) {
                badge = 'Current';
                badgeCls = 'badge current';
            } else if (p.recommended) {
                badge = 'Recommended';
            }
            const changeLabel =
                p.change && p.monthlyChange !== null && p.monthlyChange !== undefined
                    ? `${p.change} · ${monthly(p.monthlyChange)}`
                    : p.change;
            return {
                ...p,
                priceLabel: `${money(p.price)}/mo`,
                changeLabel: p.current && p.change !== 'Remove' ? null : changeLabel,
                cls: `addon${on ? ' on' : ''}${p.current ? ' current' : ''}`,
                badge,
                badgeCls,
                disabled: !this.canChange || (p.current && p.change !== 'Remove')
            };
        });
    }
    get tiersView() {
        return this.view(this.state ? this.state.tiers : []);
    }
    get addOnPlansView() {
        return this.view(this.state ? this.state.addOnPlans : []);
    }
    choose(event) {
        const sku = event.currentTarget.dataset.sku;
        this.selectedSku = this.selectedSku === sku ? undefined : sku;
    }

    // ---------- approve ----------
    get selected() {
        return this.allPlans.find((p) => p.sku === this.selectedSku);
    }
    get hasSelection() {
        return !!this.selected;
    }
    get newTotal() {
        return (this.state ? this.state.monthlyTotal : 0) + (this.selected ? this.selected.monthlyChange || 0 : 0);
    }
    get currentTotalLabel() {
        return `${money(this.state && this.state.monthlyTotal)}/mo`;
    }
    get newTotalLabel() {
        return `${money(this.newTotal)}/mo`;
    }
    get startLabel() {
        return day(this.state && this.state.startDate);
    }
    get approveLabel() {
        const p = this.selected;
        if (!p) return '';
        const verb = { Upgrade: 'upgrade', Downgrade: 'downgrade', Add: 'adding', Remove: 'removing' }[p.change];
        return `Customer approves ${verb} ${p.change === 'Upgrade' || p.change === 'Downgrade' ? 'to ' : ''}${p.name}`;
    }
    get cannotApprove() {
        return this.busy || !this.hasSelection || !this.approver || !this.approver.trim();
    }
    handleApprover(event) {
        this.approver = event.target.value;
    }
    async approve() {
        this.busy = true;
        this.error = undefined;
        try {
            this.apply(await applyChange({ recordId: this.recordId, sku: this.selectedSku, approvedBy: this.approver }));
            this.selectedSku = undefined;
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.busy = false;
        }
    }
}
