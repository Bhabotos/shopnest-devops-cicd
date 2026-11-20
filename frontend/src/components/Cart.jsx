import { cartTotal, maxQuantity } from '../cart.js';
import { formatMoney } from '../format.js';
import QuantityInput from './QuantityInput.jsx';

export default function Cart({ lines, dispatch, onBack, onCheckout }) {
  if (lines.length === 0) {
    return (
      <section>
        <h2>Your cart</h2>
        <p>Your cart is empty.</p>
        <button type="button" onClick={onBack}>Continue shopping</button>
      </section>
    );
  }

  // The API prices every product in one currency; the cart total uses the first line's.
  const currency = lines[0].product.price.currency;

  return (
    <section>
      <h2>Your cart</h2>
      <ul>
        {lines.map(({ product, quantity }) => (
          <li key={product.id} className="line">
            <span>{product.name}</span>
            <QuantityInput
              label={`Quantity for ${product.name}`}
              value={quantity}
              max={maxQuantity(product)}
              onChange={(next) => dispatch({ type: 'setQuantity', productId: product.id, quantity: next })}
            />
            <span>{formatMoney(product.price.amountMinor * quantity, product.price.currency)}</span>
            <button type="button" onClick={() => dispatch({ type: 'remove', productId: product.id })}>
              Remove {product.name}
            </button>
          </li>
        ))}
      </ul>
      <p className="total">Total: {formatMoney(cartTotal(lines), currency)}</p>
      <button type="button" onClick={onBack}>Continue shopping</button>
      <button type="button" onClick={onCheckout}>Proceed to checkout</button>
    </section>
  );
}
