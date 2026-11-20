import { formatMoney } from '../format.js';

export default function Confirmation({ order, onDone }) {
  return (
    <section>
      <h2>Thank you for your order</h2>
      <p>
        Order reference: <strong>{order.id}</strong>
      </p>
      <p>Total: {formatMoney(order.total.amountMinor, order.total.currency)}</p>
      <button type="button" onClick={onDone}>Keep shopping</button>
    </section>
  );
}
