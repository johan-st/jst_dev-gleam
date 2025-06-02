import { Link } from './ui/link'

export default function Header() {
  return (
    <header className="p-2 flex gap-2 bg-zinc-800 text-zinc-200 justify-between">
      <nav className="flex flex-row">
        <div className="px-2 font-bold hover:text-pink-700">
          <Link to="/" activeProps={{ className: 'underline text-pink-700' }}>
            Home
          </Link>
        </div>
        <div className="px-2 font-bold hover:text-pink-700">
          <Link
            to="/about"
            activeProps={{ className: 'underline text-pink-700' }}
          >
            About
          </Link>
        </div>
      </nav>
    </header>
  )
}
