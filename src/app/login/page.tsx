export default function LoginPage() {
  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-900 px-4">
      <div className="max-w-md w-full bg-slate-800 rounded-xl shadow-2xl p-8 border border-slate-700">
        <div className="text-center mb-8">
          <h1 className="text-2xl font-bold text-white tracking-wide">Corban SaaS</h1>
          <p className="text-sm text-slate-400 mt-2">Acesse o painel do Correspondente Bancário</p>
        </div>

        <form className="space-y-6">
          <div>
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300 mb-2">
              E-mail Corporativo
            </label>
            <input
              name="email"
              type="email"
              required
              className="w-full bg-slate-900 border border-slate-700 rounded-lg px-4 py-3 text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-blue-500 transition-all text-sm"
              placeholder="seu.email@corban.com"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-300 mb-2">
              Senha de Acesso
            </label>
            <input
              name="password"
              type="password"
              required
              className="w-full bg-slate-900 border border-slate-700 rounded-lg px-4 py-3 text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-blue-500 transition-all text-sm"
              placeholder="••••••••"
            />
          </div>

          <button
            type="submit"
            className="w-full bg-blue-600 hover:bg-blue-500 text-white font-medium py-3 rounded-lg transition-colors shadow-lg shadow-blue-600/20 text-sm"
          >
            Entrar no Sistema
          </button>
        </form>
      </div>
    </div>
  )
}
