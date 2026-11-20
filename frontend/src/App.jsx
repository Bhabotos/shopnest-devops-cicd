import { useEffect, useReducer, useState } from 'react';
import { fetchProducts } from './api.js';
import { cartCount, cartReducer } from './cart.js';
import Cart from './components/Cart.jsx';
import CheckoutForm from './components/CheckoutForm.jsx';
import Confirmation from './components/Confirmation.jsx';
import ProductList from './components/ProductList.jsx';

export default function App() {
  const [view, setView] = useState('catalog');
  const [products, setProducts] = useState([]);
  const [status, setStatus] = useState('loading');
  const [order, setOrder] = useState(null);
  const [lines, dispatch] = useReducer(cartReducer, []);

  const loadProducts = () => {
    setStatus('loading');
    fetchProducts()
      .then((items) => {
        setProducts(items);
        setStatus('ready');
      })
      .catch(() => setStatus('error'));
  };

  useEffect(loadProducts, []);

  const handlePlaced = (placed) => {
    setOrder(placed);
    dispatch({ type: 'clear' });
    setView('confirmation');
    loadProducts();
  };

  return (
    <>
      <header>
        <h1>ShopNest</h1>
        <button type="button" onClick={() => setView('cart')}>
          Cart ({cartCount(lines)})
        </button>
      </header>
      <main>
        {view === 'catalog' && status === 'loading' && <p role="status">Loading products...</p>}
        {view === 'catalog' && status === 'error' && (
          <div role="alert">
            <p>We could not load products.</p>
            <button type="button" onClick={loadProducts}>Retry</button>
          </div>
        )}
        {view === 'catalog' && status === 'ready' && (
          <ProductList products={products} onAdd={(product) => dispatch({ type: 'add', product })} />
        )}
        {view === 'cart' && (
          <Cart
            lines={lines}
            dispatch={dispatch}
            onBack={() => setView('catalog')}
            onCheckout={() => setView('checkout')}
          />
        )}
        {view === 'checkout' && (
          <CheckoutForm lines={lines} onPlaced={handlePlaced} onBack={() => setView('cart')} />
        )}
        {view === 'confirmation' && order && (
          <Confirmation order={order} onDone={() => setView('catalog')} />
        )}
      </main>
    </>
  );
}
