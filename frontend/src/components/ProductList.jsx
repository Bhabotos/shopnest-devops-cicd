import { formatMoney } from '../format.js';

export default function ProductList({ products, onAdd }) {
  return (
    <ul className="grid" aria-label="Products">
      {products.map((p) => (
        <li key={p.id} className="card">
          <img src={p.imageUrl} alt="" width="320" height="240" />
          <h3>{p.name}</h3>
          <p>{p.description}</p>
          <p className="price">{formatMoney(p.price.amountMinor, p.price.currency)}</p>
          {p.stock > 0 ? (
            <button type="button" onClick={() => onAdd(p)}>
              Add {p.name} to cart
            </button>
          ) : (
            <p role="status">Out of stock</p>
          )}
        </li>
      ))}
    </ul>
  );
}
