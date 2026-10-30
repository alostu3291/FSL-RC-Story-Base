import { LightningElement, api } from 'lwc';
import getState from '@salesforce/apex/RLM_RTK_PlanChange.getState';
import applyChange from '@salesforce/apex/RLM_RTK_PlanChange.applyChange';
import aiSuggestions from '@salesforce/apex/RLM_RTK_PlanChange.aiSuggestions';

const money = (value) => {
    const cents = Math.round((value || 0) * 100) / 100;
    const digits = Number.isInteger(cents) ? 0 : 2;
    return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD',
        minimumFractionDigits: digits,
        maximumFractionDigits: digits
    }).format(cents);
};

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
    /** Einstein's extra picks from the finding notes, sku to reason. Prices and approval are unchanged. */
    aiPicks = {};
    aiBusy = false;
    aiMessage;

    connectedCallback() {
        this.load();
    }

    @api
    refresh() {
        return this.load();
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
        const recommended = this.allPlans.filter((p) => p.recommended).length;
        const hint = recommended && this.canChange ? ` · ${recommended} recommended from findings` : '';
        return `${plan} · ${money(this.state.monthlyTotal)}/mo${hint}`;
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
            } else if (this.aiPicks[p.sku]) {
                badge = 'Einstein suggests';
                badgeCls = 'badge ai';
            }
            const reason = p.recommended ? p.reason : !p.current && this.aiPicks[p.sku];
            const changeLabel =
                p.change && p.monthlyChange !== null && p.monthlyChange !== undefined
                    ? `${p.change} · ${monthly(p.monthlyChange)}`
                    : p.change;
            return {
                ...p,
                reason,
                priceLabel: `${money(p.price)}/mo`,
                splitLabel: p.adjustment > 0 ? `${money(p.listPrice)} list + ${money(p.adjustment)} size and severity adjustment` : null,
                changeLabel: p.current && p.change !== 'Remove' ? null : changeLabel,
                cls: `addon${on ? ' on' : ''}${p.current ? ' current' : ''}`,
                badge,
                badgeCls,
                disabled: !this.canChange || (p.current && p.change !== 'Remove')
            };
        });
    }
    get aiLabel() {
        return this.aiBusy ? 'Reading the notes…' : 'Ask Einstein';
    }

    /** Reads the finding notes for plans the fixed rules missed; the customer still approves. */
    async askEinstein() {
        this.aiBusy = true;
        this.aiMessage = undefined;
        try {
            const picks = await aiSuggestions({ recordId: this.recordId });
            const next = {};
            (picks || []).forEach((p) => {
                next[p.sku] = p.reason;
            });
            this.aiPicks = next;
            this.aiMessage = picks && picks.length
                ? `Einstein found ${picks.length} more from the notes. The customer still approves.`
                : 'Einstein didn’t find another plan in the notes.';
        } catch (e) {
            this.aiMessage = 'Einstein isn’t available right now. The rules still apply.';
        } finally {
            this.aiBusy = false;
        }
    }

    get hasAdjustment() {
        return !!(this.state && this.state.adjustment > 0);
    }
    get adjustmentNote() {
        const amount = money(this.state.adjustment);
        const why = this.state.adjustmentReasons ? ` (${this.state.adjustmentReasons})` : ' for home size and severity';
        return `This home's plan price includes a ${amount}/mo size and severity adjustment${why}. It stays the same when the plan changes; only the list price moves.`;
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
    /** "Home Protection $79 → Home Protection Plus $99 (+$20/mo; adjustment unchanged)" */
    get changeLine() {
        const p = this.selected;
        if (!p) return '';
        const isTier = this.state.tiers.some((t) => t.sku === p.sku);
        const from = isTier ? this.state.tiers.find((t) => t.current) : null;
        if (from) {
            const kept = p.adjustment > 0 ? '; adjustment unchanged' : '';
            return `${from.name} ${money(from.price)} → ${p.name} ${money(p.price)} (${monthly(p.monthlyChange || 0)}${kept})`;
        }
        if (p.change === 'Remove') return `Removing ${p.name} (${monthly(-p.price)})`;
        return `Adding ${p.name} (${monthly(p.price)})`;
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
