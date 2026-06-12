import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import AdminDashboard from './AdminDashboard'

import { Auth } from '@supabase/auth-ui-react'
import { ThemeSupa } from '@supabase/auth-ui-shared'

// Eliminamos la lógica de getUserId() ya que ahora usamos Supabase Auth

const parseDownloadProgress = (msg) => {
  if (!msg) return null;
  const dlMatch = msg.match(/(Descargando juego|Verificando archivos|Instalando juego|Validando 2FA y descargando):\s*([\d.]+)%\s*(?:\(([^)]+)\))?\s*(?:@\s*([^ ]+))?\s*(?:-\s*(.*))?/i);
  if (dlMatch) {
    return {
      action: dlMatch[1],
      progress: parseFloat(dlMatch[2]),
      sizes: dlMatch[3] || '',
      speed: dlMatch[4] || '',
      eta: dlMatch[5] || '',
    };
  }
  return null;
};

function App() {
  const [games, setGames] = useState([])
  const [session, setSession] = useState(null)
  const [authSession, setAuthSession] = useState(null)
  const [userData, setUserData] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)
  const [activeServers, setActiveServers] = useState(0)
  const [isAdminView, setIsAdminView] = useState(false)
  const [elapsedSeconds, setElapsedSeconds] = useState(0)
  // Modal de Steam reactivo (aparece cuando la VM lo pide)
  const [showSteamModal, setShowSteamModal] = useState(false)
  const [steamWaitMode, setSteamWaitMode] = useState('credentials') // 'credentials' | '2fa'
  const [steamCredentials, setSteamCredentials] = useState({ username: '', password: '' })
  const [steamAuthCode, setSteamAuthCode] = useState('')
  const [steamError, setSteamError] = useState(null)
  const [steamSubmitting, setSteamSubmitting] = useState(false)
  const [rememberSteam, setRememberSteam] = useState(false)
  const [preLaunchGameId, setPreLaunchGameId] = useState(null)
  // Timeout: si provisioning supera 2 min sin cambio de status_message, avisamos al usuario
  const [provisioningTimeout, setProvisioningTimeout] = useState(false)
  const [lastStatusMessage, setLastStatusMessage] = useState(null)

  useEffect(() => {
    // 1. Manejar Sesión de Autenticación
    supabase.auth.getSession().then(({ data: { session } }) => {
      setAuthSession(session)
      if (session) fetchUserProfile(session.user.id)
    })

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setAuthSession(session)
      if (session) fetchUserProfile(session.user.id)
      else setUserData(null)
    })

    return () => subscription.unsubscribe()
  }, [])

  const fetchUserProfile = async (userId) => {
    const { data } = await supabase
      .from('users')
      .select('*')
      .eq('id', userId)
      .single()
    setUserData(data)
    // Pre-rellenar credenciales guardadas para ahorrar tiempo al usuario
    if (data?.metadata?.steam_username && data?.metadata?.steam_password) {
      setSteamCredentials({
        username: data.metadata.steam_username,
        password: data.metadata.steam_password
      })
      setRememberSteam(true)
    }
  }

  // Reaccionar cuando la VM entra en waiting_steam_auth — detectar modo automáticamente
  useEffect(() => {
    // La aprobación de código de Steam (2FA) ha sido desactivada temporalmente a petición del usuario.
    setShowSteamModal(false)
  }, [session?.status, session?.status_message])

  // ── Detector de timeout: si el mensaje no cambia en 2 minutos durante provisioning ─
  useEffect(() => {
    setProvisioningTimeout(false)
    if (!session || session.status !== 'provisioning') {
      setLastStatusMessage(null)
      return
    }
    setLastStatusMessage(session.status_message)
    const timer = setTimeout(() => {
      // Si tras 2 minutos el mensaje sigue igual (sin avance), avisamos
      setProvisioningTimeout(true)
    }, 120_000)  // 2 minutos
    return () => clearTimeout(timer)
  }, [session?.status_message, session?.status])

  useEffect(() => {
    let interval = null;
    // Cronómetro activo en todos los estados de espera/instalación
    const waitingStatuses = ['pending', 'provisioning', 'loading_save', 'waiting_steam_auth'];
    if (session && waitingStatuses.includes(session.status)) {
      interval = setInterval(() => {
        setElapsedSeconds(prev => prev + 1);
      }, 1000);
    } else {
      setElapsedSeconds(0);
      clearInterval(interval);
    }
    return () => clearInterval(interval);
  }, [session?.status]);

  useEffect(() => {
    if (!authSession) return

    fetchGames()
    checkActiveSession()
    fetchActiveServersCount()

    // Suscribirse a TODOS los cambios en sessions para mantener el contador global actualizado
    const sessionSubscription = supabase
      .channel('public:sessions')
      .on('postgres_changes', { 
        event: '*', 
        schema: 'public', 
        table: 'sessions',
      }, (payload) => {
        // Si el cambio es de nuestra propia sesión, la actualizamos
        if (payload.new && payload.new.user_id === authSession.user.id) {
          setSession(payload.new.status === 'completed' ? null : payload.new)
        }
        // Actualizar siempre el conteo global de servidores
        fetchActiveServersCount()
      })
      .subscribe()

    return () => {
      supabase.removeChannel(sessionSubscription)
    }
  }, [authSession])

  const fetchGames = async () => {
    const { data } = await supabase.from('games').select('*')
    setGames(data || [])
  }

  const checkActiveSession = async () => {
    if (!authSession) return
    const { data } = await supabase
      .from('sessions')
      .select('*')
      .eq('user_id', authSession.user.id)
      .in('status', ['pending', 'provisioning', 'loading_save', 'playing', 'waiting_steam_auth', 'failed'])
      .limit(1)
      
    if (data && data.length > 0) {
      setSession(data[0])
    }
  }

  const fetchActiveServersCount = async () => {
    const { count, error } = await supabase
      .from('sessions')
      .select('*', { count: 'exact', head: true })
      .in('status', ['pending', 'provisioning', 'loading_save', 'playing'])
    
    if (!error && count !== null) {
      setActiveServers(count)
    }
  }

  // Crear sesión — siempre con SESSION_ID fresco
  const handlePlay = async (gameId) => {
    if (activeServers >= 8 || !authSession || loading) return

    // Pre-launch credentials check
    if (!steamCredentials.username || !steamCredentials.password) {
      setPreLaunchGameId(gameId)
      setSteamWaitMode('credentials')
      setShowSteamModal(true)
      return
    }

    // Bloquear botón inmediatamente para evitar doble-click
    setLoading(true)
    setError(null)
    setProvisioningTimeout(false)

    try {
      // Limpiar sesiones anteriores de este usuario que estén en 'failed' o 'completed'
      // para garantizar un SESSION_ID fresco sin conflictos con pods anteriores.
      await supabase
        .from('sessions')
        .update({ status: 'completed' })
        .eq('user_id', authSession.user.id)
        .in('status', ['failed', 'completed'])

      const { data, error: rpcErr } = await supabase.rpc('allocate_game_session', {
        p_game_id: gameId,
        p_user_id: authSession.user.id
      })
      if (rpcErr) throw rpcErr
      const sessionId = data[0].session_id

      // Update session with credentials immediately
      await supabase.from('sessions').update({
        steam_username: steamCredentials.username,
        steam_password: steamCredentials.password
      }).eq('id', sessionId)

      const { data: newSession } = await supabase
        .from('sessions').select('*').eq('id', sessionId).single()
      setSession(newSession)
    } catch (err) {
      setError(err.message || 'Error al iniciar la sesión de juego')
    } finally {
      setLoading(false)
    }
  }

  // Enviar credenciales a Supabase para que la VM las recoja o antes de crear la sesión
  const handleSteamCredentialsSubmit = async () => {
    if (!steamCredentials.username.trim() || !steamCredentials.password.trim()) {
      setSteamError('Ingresa tu usuario y contraseña de Steam.')
      return
    }
    setSteamError(null)
    setSteamSubmitting(true)
    try {
      if (session) {
        await supabase.from('sessions').update({
          steam_username: steamCredentials.username.trim(),
          steam_password: steamCredentials.password,
        }).eq('id', session.id)
      }

      // Guardar credenciales si el usuario lo pidió o si estamos en pre-launch
      if (rememberSteam || (!session && preLaunchGameId)) {
        await supabase.from('users').update({
          metadata: { ...userData?.metadata, steam_username: steamCredentials.username.trim(), steam_password: steamCredentials.password }
        }).eq('id', authSession.user.id)
        setUserData(prev => ({ ...prev, metadata: { ...prev?.metadata, steam_username: steamCredentials.username.trim(), steam_password: steamCredentials.password } }))
      }

      // Si estamos en pre-launch, creamos la sesión ahora
      if (!session && preLaunchGameId) {
        const { data, error: rpcErr } = await supabase.rpc('allocate_game_session', {
          p_game_id: preLaunchGameId,
          p_user_id: authSession.user.id
        })
        if (rpcErr) throw rpcErr
        const sessionId = data[0].session_id
        
        await supabase.from('sessions').update({
          steam_username: steamCredentials.username.trim(),
          steam_password: steamCredentials.password,
        }).eq('id', sessionId)

        const { data: newSession } = await supabase
          .from('sessions').select('*').eq('id', sessionId).single()
        setSession(newSession)
        
        setShowSteamModal(false)
        setPreLaunchGameId(null)
        setSteamSubmitting(false)
        return
      }

      // El modal se cerrará cuando la VM cambie el status (via realtime)
      // Mantenemos steamSubmitting=true para que el usuario vea el loader hasta que la VM cambie el status
    } catch (err) {
      setSteamError(err.message || 'Error al enviar credenciales')
      setSteamSubmitting(false)
    }
  }

  // Enviar código 2FA a Supabase para que la VM lo recoja
  const handleSteam2FASubmit = async () => {
    if (!steamAuthCode.trim()) {
      setSteamError('Ingresa el código de autenticación.')
      return
    }
    setSteamError(null)
    setSteamSubmitting(true)
    try {
      await supabase.from('sessions').update({
        steam_2fa_code: steamAuthCode.trim(),
      }).eq('id', session.id)
      setSteamAuthCode('')
      // Mantenemos steamSubmitting=true hasta que la VM procese el código y cambie el estado
    } catch (err) {
      setSteamError(err.message || 'Error al enviar el código')
      setSteamSubmitting(false)
    }
  }

  // (handle2FASubmit eliminado — reemplazado por handleSteam2FASubmit en modal unificado)

  const [moonlightPin, setMoonlightPin] = useState('')
  const [pairingLoading, setPairingLoading] = useState(false)

  // ... (existing code)

  const handlePairMoonlight = async () => {
    if (!moonlightPin.trim() || moonlightPin.length < 4) {
      alert('Ingresa un PIN válido de 4 dígitos.')
      return
    }
    setPairingLoading(true)
    try {
      const { error } = await supabase
        .from('sessions')
        .update({ moonlight_pin: moonlightPin.trim() })
        .eq('id', session.id)
      
      if (error) throw error
      setMoonlightPin('')
      alert('¡PIN enviado! Tu servidor se emparejará en unos segundos.')
    } catch (err) {
      alert('Error al enviar el PIN: ' + err.message)
    } finally {
      setPairingLoading(false)
    }
  }

  const handleStopSession = async () => {
    if (!session) return;
    setLoading(true)
    try {
      const { error } = await supabase
        .from('sessions')
        .update({ status: 'completed' })
        .eq('id', session.id)

      if (error) throw error
      setSession(null)
    } catch (err) {
      setError('Error al finalizar la sesión')
    } finally {
      setLoading(false)
    }
  }

  const handleRetryInstallation = async () => {
    if (!session) return;
    setLoading(true);
    setError(null);
    try {
      const { error } = await supabase
        .from('sessions')
        .update({ 
          status: 'pending', 
          status_message: 'Reintentando instalación... El orquestador preparará la máquina.',
          steam_2fa_code: null 
        })
        .eq('id', session.id);
      if (error) throw error;
      setSession(prev => ({ 
        ...prev, 
        status: 'pending', 
        status_message: 'Reintentando instalación... El orquestador preparará la máquina.',
        steam_2fa_code: null 
      }));
    } catch (err) {
      console.error("Error retrying installation:", err);
      alert('Error al reiniciar la instalación: ' + err.message);
    } finally {
      setLoading(false);
    }
  }

  const handleLogout = async () => {
    await supabase.auth.signOut()
  }

  if (!authSession) {
    return (
      <div className="min-h-screen bg-[#050505] flex items-center justify-center p-6 font-inter">
        <div className="absolute inset-0 z-0 overflow-hidden">
          <div className="absolute top-[-10%] left-[-10%] w-[40%] h-[40%] bg-violet-600/20 blur-[120px] rounded-full"></div>
          <div className="absolute bottom-[-10%] right-[-10%] w-[40%] h-[40%] bg-blue-600/10 blur-[120px] rounded-full"></div>
        </div>

        <div className="relative z-10 w-full max-w-md">
          <div className="text-center mb-10">
            <h1 className="text-4xl font-black italic tracking-tighter text-white mb-2">AETHER CLOUD</h1>
            <p className="text-violet-400 font-label-caps tracking-widest text-xs uppercase">Next-Gen Gaming Infrastructure</p>
          </div>

          <div className="glass-panel p-8 rounded-2xl border border-white/10 shadow-[0_0_50px_rgba(139,92,246,0.15)]">
            <Auth
              supabaseClient={supabase}
              appearance={{
                theme: ThemeSupa,
                variables: {
                  default: {
                    colors: {
                      brand: '#8B5CF6',
                      brandAccent: '#7C3AED',
                      inputText: 'white',
                      inputBackground: 'rgba(255,255,255,0.05)',
                      inputBorder: 'rgba(255,255,255,0.1)',
                      inputPlaceholder: '#666',
                    },
                    radii: {
                      borderRadiusButton: '12px',
                      buttonPadding: '12px',
                      inputPadding: '12px',
                    }
                  }
                },
                className: {
                  container: 'auth-container',
                  button: 'auth-button font-bold tracking-widest uppercase text-xs',
                  input: 'auth-input text-white border-white/10 focus:border-violet-500/50 transition-all',
                  label: 'auth-label text-gray-400 text-[10px] uppercase tracking-widest mb-1 block',
                }
              }}
              providers={[]}
              localization={{
                variables: {
                  sign_in: {
                    email_label: 'CORREO ELECTRÓNICO',
                    password_label: 'CONTRASEÑA',
                    button_label: 'INICIAR SESIÓN',
                  },
                  sign_up: {
                    email_label: 'CORREO ELECTRÓNICO',
                    password_label: 'CONTRASEÑA',
                    button_label: 'REGISTRARSE',
                  }
                }
              }}
            />
          </div>
          
          <p className="text-center mt-8 text-gray-500 text-[10px] uppercase tracking-[0.2em]">
            &copy; 2026 AETHER INFRASTRUCTURE GROUP
          </p>
        </div>
      </div>
    )
  }

  const isServerFull = activeServers >= 8;

  if (isAdminView) {
    return (
      <div className="bg-background text-on-background font-body-base overflow-x-hidden min-h-screen selection:bg-primary-container selection:text-on-primary-container">
        <header className="fixed top-0 w-full h-16 z-50 flex items-center justify-between px-6 bg-[#050505]/90 backdrop-blur-2xl border-b border-[#262626] shadow-[0_4px_20px_rgba(139,92,246,0.1)]">
          <div className="flex items-center gap-container-margin">
            <div className="text-xl font-black italic tracking-tighter text-white font-inter">AETHER CLOUD</div>
          </div>
          <button 
            onClick={() => setIsAdminView(false)}
            className="flex items-center gap-2 bg-surface-container hover:bg-surface-bright text-on-surface px-4 py-2 rounded-lg transition-colors border border-outline-variant font-label-caps tracking-widest text-xs"
          >
            VOLVER AL CLIENTE
          </button>
        </header>
        <main className="pt-16 min-h-screen">
          <AdminDashboard />
        </main>
      </div>
    )
  }

    const renderActiveSession = () => {
    const game = games.find(g => g.id === session.game_id);
    const gameName = game ? game.name : 'Unknown Game';
    
    // RunPod public IP (almacenada como ip_address tras bootstrap SSH) — sin VPN, directa
    const connectIp = session.ip_address
      || (session.status_message && session.status_message.match(/[\d]{1,3}\.[\d]{1,3}\.[\d]{1,3}\.[\d]{1,3}/)?.[0]);
    const extractedIp = connectIp;
    
    if (session.status === 'playing') {
      return (
        <div className="relative z-20 h-[calc(100vh-64px)] w-full flex items-center justify-center pointer-events-auto">
          {/* Active Session TopAppBar overlay */}
          <nav className="absolute top-8 left-1/2 -translate-x-1/2 w-full max-w-xl h-10 z-[60] flex items-center justify-between px-4 bg-violet-900/20 backdrop-blur-xl rounded-full border border-violet-500/30 shadow-[0_0_30px_rgba(139,92,246,0.4)]">
            <div className="flex items-center gap-3">
              <div className="relative flex h-2 w-2">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
                <span className="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>
              </div>
              <span className="text-white text-xs font-bold font-label-caps tracking-widest uppercase">Active Session: {gameName}</span>
            </div>
            <div className="flex items-center gap-4">
              <div className="flex items-center gap-1.5 text-violet-400 font-inter font-bold uppercase tracking-widest text-[10px]">
                <span className="material-symbols-outlined text-[14px]">signal_cellular_alt</span>
                <span>12ms</span>
              </div>
              <div className="h-4 w-[1px] bg-violet-500/30 mx-1"></div>
              <button 
                onClick={handleStopSession}
                className="text-white font-inter font-bold uppercase tracking-widest text-[10px] py-1.5 px-3 rounded-full hover:bg-red-500/20 hover:text-red-400 transition-colors flex items-center gap-1"
              >
                  END SESSION
              </button>
            </div>
          </nav>
          
          <div className="flex flex-col items-center justify-center gap-6 z-50">
            {/* Badge Moonlight */}
            <div className="flex items-center gap-2 px-3 py-1 rounded-full text-[10px] font-mono font-bold border bg-emerald-500/10 border-emerald-500/30 text-emerald-400">
              <span className="material-symbols-outlined text-[13px]">cast</span>
              Sunshine Streaming · Ready
            </div>

            <div className="flex flex-col items-center gap-3 text-center bg-[#FF4500]/5 border border-[#FF4500]/20 backdrop-blur-md w-full max-w-md p-6 rounded-2xl mt-4">
              <span className="material-symbols-outlined text-[48px] text-[#FF4500]">devices</span>
              <h3 className="text-white font-bold text-lg">Tu Servidor Sunshine está listo</h3>
              
              <div className="w-full bg-black/40 rounded-xl p-4 my-2 border border-white/5">
                <p className="text-gray-400 text-[10px] uppercase tracking-widest mb-1">Abre Moonlight y agrega esta IP:</p>
                <code className="text-[#FF4500] font-mono text-xl">{extractedIp}</code>
              </div>

              {session.web_url && (
                <a 
                  href={session.web_url} 
                  target="_blank" 
                  rel="noopener noreferrer"
                  className="w-full mt-2 py-4 bg-gradient-to-r from-emerald-600 to-teal-500 hover:from-emerald-500 hover:to-teal-400 text-white rounded-xl font-bold uppercase tracking-widest text-sm transition-all shadow-[0_0_20px_rgba(16,185,129,0.4)] flex items-center justify-center gap-2"
                >
                  <span className="material-symbols-outlined">sports_esports</span>
                  Jugar en el Navegador
                </a>
              )}

              {session.moonlight_pin ? (
                <div className="w-full bg-green-500/10 border border-green-500/30 rounded-xl p-4 animate-pulse mt-4">
                  <p className="text-green-400 font-bold text-sm">PIN Enviado ✓</p>
                  <p className="text-gray-400 text-xs mt-1">El servidor está autorizando tu dispositivo...</p>
                </div>
              ) : (
                <div className="w-full mt-4">
                  <p className="text-gray-400 text-sm leading-relaxed mb-3">
                    Introduce el <strong>PIN de 4 dígitos</strong> que te da Moonlight para autorizar la conexión:
                  </p>
                  <div className="flex items-center gap-2">
                    <input 
                      type="text" 
                      maxLength="4"
                      value={moonlightPin}
                      onChange={(e) => setMoonlightPin(e.target.value.replace(/[^0-9]/g, ''))}
                      className="flex-1 bg-white/5 border border-white/10 rounded-xl px-4 py-3 text-white text-center text-xl font-mono tracking-[0.5em] outline-none focus:border-[#FF4500]/50 focus:shadow-[0_0_15px_rgba(255,69,0,0.15)] transition-all"
                      placeholder="XXXX"
                    />
                    <button 
                      onClick={handlePairMoonlight}
                      disabled={pairingLoading || moonlightPin.length !== 4}
                      className="px-6 py-3 bg-[#FF4500] hover:bg-[#FF6347] disabled:bg-gray-700 disabled:text-gray-400 text-white rounded-xl font-bold uppercase tracking-widest text-xs transition-all shadow-[0_0_15px_rgba(255,69,0,0.3)] disabled:shadow-none"
                    >
                      {pairingLoading ? 'Enviando...' : 'Vincular'}
                    </button>
                  </div>
                </div>
              )}
            </div>
          </div>
          
          {/* Subtle vignette */}
          <div className="absolute inset-0 z-10 bg-gradient-to-b from-background/40 via-transparent to-background/60 pointer-events-none"></div>
        </div>
      );
    }
    
    // Loading State
    return (
      <div className="fixed inset-0 z-40 bg-background/70 backdrop-blur-3xl flex items-center justify-center p-container-margin">
        <div className="relative w-full max-w-2xl bg-surface-container-low/80 border border-outline-variant/40 rounded-xl p-section-gap flex flex-col items-center bloom-shadow">
          <div className="text-center mb-stack-lg flex flex-col items-center">
            <div className="bg-primary/10 border border-primary/20 px-3 py-1 rounded-full mb-stack-md flex items-center gap-2">
              <span className="material-symbols-outlined text-[14px] text-primary" style={{fontVariationSettings: "'FILL' 1"}}>cloud_done</span>
              <span className="font-label-caps text-primary tracking-widest">AETHER CLOUD INSTANCE</span>
            </div>
            <h1 className="font-display-lg text-on-surface">{gameName}</h1>
            <p className="font-body-base text-secondary mt-stack-sm">Initializing high-performance rig</p>
          </div>

          <div className="relative w-48 h-48 mb-section-gap flex items-center justify-center">
            <svg className="absolute inset-0 w-full h-full transform -rotate-90 animate-spin" viewBox="0 0 100 100" style={{animationDuration: '3s'}}>
              <circle className="stroke-surface-variant" cx="50" cy="50" fill="none" r="46" strokeWidth="2"></circle>
              <circle className="stroke-primary" cx="50" cy="50" fill="none" r="46" strokeDasharray="289.02" strokeDashoffset={session.status === 'pending' ? "200" : "100"} strokeLinecap="round" strokeWidth="4" style={{transition: 'all 1s ease-in-out'}}></circle>
            </svg>
            <div className="relative z-10 w-24 h-24 bg-surface-container rounded-full flex items-center justify-center border border-outline-variant/50 shadow-inner">
              <span className="material-symbols-outlined text-[48px] text-primary" style={{fontVariationSettings: "'FILL' 1"}}>sports_esports</span>
            </div>
            <div className="absolute inset-0 bg-primary/20 rounded-full blur-2xl -z-10"></div>
          </div>

          <div className="w-full max-w-md flex flex-col gap-stack-sm">
            {session.status === 'loading_save' ? (
              <>
                <div className="flex items-center gap-4 px-4 py-3 rounded-lg bg-surface-container border border-primary/30 relative overflow-hidden">
                  <div className="absolute left-0 top-0 bottom-0 w-1 bg-primary"></div>
                  <span className="material-symbols-outlined text-[24px] text-primary animate-spin" style={{fontVariationSettings: "'FILL' 1"}}>sync</span>
                  <div className="flex flex-col">
                    <span className="font-title-lg text-primary">{session.status_message || 'Iniciando Windows y ejecutando script...'}</span>
                    <span className="text-secondary text-xs">Tiempo de espera: {elapsedSeconds}s (Estimado: ~60s)</span>
                  </div>
                </div>
                
                {extractedIp && (
                  <div className="mt-4 p-4 rounded-xl bg-primary/10 border border-primary/20 animate-fade-in">
                    <p className="font-label-caps text-primary text-[11px] mb-2">SUNSHINE CONTROL PANEL</p>
                    <div className="flex items-center justify-between gap-3 bg-black/40 p-3 rounded-lg border border-white/5">
                      <code className="text-primary font-mono text-sm overflow-hidden text-ellipsis">
                        https://{extractedIp}:20242
                      </code>
                      <button 
                        onClick={() => {
                          navigator.clipboard.writeText(`https://${extractedIp}:20242`);
                          alert("Link copiado!");
                        }}
                        className="p-2 hover:bg-primary/20 rounded-md transition-colors text-primary"
                      >
                        <span className="material-symbols-outlined text-[18px]">content_copy</span>
                      </button>
                    </div>
                  </div>
                )}
                
                <button 
                  onClick={async () => {
                    if (!window.confirm('¿Estás seguro de que deseas cancelar la sesión? La máquina se está creando en los servidores de TensorDock (paso que toma de 2 a 4 minutos). Si cancelas ahora, se perderá todo el progreso y el servidor se destruirá.')) return;
                    // Marcar como completada para que el orquestador limpie si hay algo
                    await supabase.from('sessions').update({ status: 'completed' }).eq('id', session.id);
                    setSession(null);
                  }}
                  className="mt-8 text-secondary hover:text-on-surface font-label-caps tracking-widest text-[12px] flex items-center justify-center gap-2 transition-colors"
                >
                  <span className="material-symbols-outlined text-[18px]">close</span>
                  CANCELAR Y VOLVER AL MENÚ
                </button>
              </>
            ) : session.status === 'waiting_steam_auth' ? (
              <div className="flex flex-col items-center gap-6 p-8 rounded-2xl bg-violet-900/20 border border-violet-500/30 max-w-md w-full animate-fade-in z-50">
                <span className="material-symbols-outlined text-[64px] text-violet-400 animate-pulse">security</span>
                <div className="text-center">
                  <h2 className="font-display-md text-white text-xl font-bold">Steam Guard Requerido</h2>
                  <p className="text-gray-400 text-sm mt-2 leading-relaxed">Por favor, revisa tu correo electrónico o la app móvil de Steam e introduce el código de acceso.</p>
                </div>
                
                <div className="flex flex-col gap-3 w-full">
                  <input 
                    type="text" 
                    id="steam_guard_input"
                    placeholder="Ej: AB12C"
                    className="w-full bg-black/50 border border-violet-500/30 rounded-xl px-4 py-3 text-white font-mono text-center text-2xl tracking-[0.2em] uppercase focus:border-violet-500 focus:outline-none transition-colors"
                    maxLength={5}
                    autoComplete="off"
                  />
                  <button 
                    onClick={async () => {
                      const code = document.getElementById('steam_guard_input').value.trim().toUpperCase();
                      if (!code) return;
                      await supabase.from('sessions').update({ steam_2fa_code: code, status_message: 'Validando código 2FA...' }).eq('id', session.id);
                    }}
                    className="w-full py-3.5 bg-gradient-to-r from-violet-600 to-indigo-600 text-white rounded-xl font-bold uppercase tracking-widest text-xs hover:from-violet-500 hover:to-indigo-500 transition-all shadow-[0_0_20px_rgba(139,92,246,0.3)] active:scale-95 mt-2"
                  >
                    ENVIAR CÓDIGO
                  </button>
                  <button 
                    onClick={async () => {
                      await supabase.from('sessions').update({ status: 'completed' }).eq('id', session.id);
                      setSession(null);
                    }}
                    className="w-full py-3 mt-2 bg-white/5 border border-white/10 hover:bg-red-500/10 hover:border-red-500/20 hover:text-red-400 text-gray-300 rounded-xl font-bold uppercase tracking-widest text-xs transition-all flex items-center justify-center gap-2"
                  >
                    <span className="material-symbols-outlined text-sm">close</span>
                    CANCELAR
                  </button>
                </div>
              </div>
            ) : session.status === 'failed' ? (
              <div className="flex flex-col items-center gap-6 p-8 rounded-2xl bg-error-container/10 border border-error/20 max-w-md w-full">
                <span className="material-symbols-outlined text-[64px] text-red-500 animate-pulse" style={{fontVariationSettings: "'FILL' 1"}}>error</span>
                <div className="text-center">
                  <h2 className="font-display-md text-white text-xl font-bold">Algo salió mal en el servidor</h2>
                  <p className="text-gray-400 text-sm mt-2 leading-relaxed">{session.status_message || 'Hubo un error al preparar tu sesión.'}</p>
                </div>
                
                <div className="flex flex-col gap-3 w-full">
                  <button 
                    onClick={handleRetryInstallation}
                    className="w-full py-3.5 bg-gradient-to-r from-violet-600 to-indigo-600 text-white rounded-xl font-bold uppercase tracking-widest text-xs hover:from-violet-500 hover:to-indigo-500 transition-all shadow-[0_0_20px_rgba(139,92,246,0.3)] active:scale-95 flex items-center justify-center gap-2"
                  >
                    <span className="material-symbols-outlined text-sm animate-spin" style={{ animationDuration: '3s' }}>build</span>
                    REINTENTAR / REPARAR INSTALACIÓN
                  </button>
                  <button 
                    onClick={async () => {
                      if (window.confirm('Esto borrará los datos de Steam guardados en tu cuenta. ¿Continuar?')) {
                        await supabase.from('users').update({ metadata: { ...userData?.metadata, steam_username: null, steam_password: null } }).eq('id', authSession.user.id);
                        setUserData(prev => ({ ...prev, metadata: { ...prev?.metadata, steam_username: null, steam_password: null } }));
                        setSteamCredentials({username: '', password: ''});
                        setRememberSteam(false);
                        await supabase.from('sessions').update({ status: 'completed' }).eq('id', session.id);
                        setSession(null);
                      }
                    }}
                    className="w-full py-3.5 bg-white/5 border border-white/10 text-gray-400 hover:bg-red-500/10 hover:border-red-500/30 hover:text-red-400 rounded-xl font-bold uppercase tracking-widest text-xs transition-all flex items-center justify-center gap-2"
                  >
                    <span className="material-symbols-outlined text-sm">account_circle_off</span>
                    BORRAR CREDENCIALES Y CANCELAR
                  </button>
                  
                  <button 
                    onClick={async () => {
                      if (!window.confirm('¿Cancelar y eliminar la máquina? Se destruirá el servidor virtual.')) return;
                      await supabase.from('sessions').update({ status: 'completed' }).eq('id', session.id);
                      setSession(null);
                    }}
                    className="w-full py-3 bg-white/5 border border-white/10 hover:bg-red-500/10 hover:border-red-500/20 hover:text-red-400 text-gray-300 rounded-xl font-bold uppercase tracking-widest text-xs transition-all flex items-center justify-center gap-2"
                  >
                    <span className="material-symbols-outlined text-sm">delete_forever</span>
                    ELIMINAR VM Y VOLVER AL MENÚ
                  </button>
                </div>
              </div>
            ) : (
              <div className="flex flex-col gap-3 w-full">
                {(() => {
                  const progressData = parseDownloadProgress(session.status_message);
                  if (progressData) {
                    return (
                      <div className="p-5 rounded-2xl bg-violet-950/20 border border-violet-500/20 backdrop-blur-md w-full animate-fade-in">
                        <div className="flex items-center justify-between mb-3">
                          <span className="text-xs uppercase font-bold text-violet-400 tracking-wider flex items-center gap-1.5 animate-pulse">
                            <span className="material-symbols-outlined text-sm">downloading</span>
                            {progressData.action}
                          </span>
                          <span className="text-sm font-mono font-bold text-white bg-violet-500/20 px-2 py-0.5 rounded">
                            {progressData.progress.toFixed(2)}%
                          </span>
                        </div>
                        
                        {/* Progress Bar Container */}
                        <div className="w-full h-3 bg-white/5 rounded-full overflow-hidden border border-white/10 relative">
                          <div 
                            className="h-full bg-gradient-to-r from-violet-600 to-indigo-500 rounded-full transition-all duration-500 ease-out shadow-[0_0_15px_rgba(139,92,246,0.6)]" 
                            style={{ width: `${progressData.progress}%` }}
                          />
                          <div className="absolute inset-0 bg-[linear-gradient(45deg,rgba(255,255,255,0.15)_25%,transparent_25%,transparent_50%,rgba(255,255,255,0.15)_50%,rgba(255,255,255,0.15)_75%,transparent_75%,transparent)] bg-[length:1rem_1rem] animate-[progress-bar-stripes_1s_linear_infinite]" />
                        </div>
                        
                        {/* Sub-info */}
                        <div className="flex items-center justify-between mt-3 text-[11px] text-gray-400 font-mono">
                          {progressData.sizes && (
                            <span className="flex items-center gap-1">
                              <span className="material-symbols-outlined text-xs">folder_open</span>
                              {progressData.sizes}
                            </span>
                          )}
                          {progressData.speed && (
                            <span className="flex items-center gap-1 text-violet-300 font-bold">
                              <span className="material-symbols-outlined text-xs">speed</span>
                              {progressData.speed}
                            </span>
                          )}
                          {progressData.eta && (
                            <span className="flex items-center gap-1 text-teal-400">
                              <span className="material-symbols-outlined text-xs">schedule</span>
                              {progressData.eta}
                            </span>
                          )}
                        </div>
                      </div>
                    );
                  }
                  
                  return (
                    <div className="flex items-center gap-4 px-4 py-3 rounded-lg bg-surface-container border border-primary/30 relative overflow-hidden">
                      <div className="absolute left-0 top-0 bottom-0 w-1 bg-primary"></div>
                      <span className="material-symbols-outlined text-[24px] text-primary animate-spin" style={{fontVariationSettings: "'FILL' 1"}}>dns</span>
                      <div className="flex flex-col">
                        <span className="font-title-lg text-primary">
                          {session.status_message || 'Allocating dedicated server...'}
                        </span>
                        <span className="text-secondary text-xs">Tiempo de espera: {elapsedSeconds}s</span>
                      </div>
                    </div>
                  );
                })()}

                {/* Banner de timeout: aparece si el mensaje no cambia en 2 minutos */}
                {provisioningTimeout && session.status === 'provisioning' && (
                  <div className="flex flex-col gap-3 p-4 rounded-xl bg-amber-950/30 border border-amber-500/30 animate-fade-in">
                    <div className="flex items-start gap-3">
                      <span className="material-symbols-outlined text-[22px] text-amber-400 mt-0.5" style={{fontVariationSettings: "'FILL' 1"}}>warning</span>
                      <div className="flex flex-col gap-1">
                        <span className="text-amber-300 font-bold text-sm">Tarda más de lo esperado</span>
                        <p className="text-amber-200/70 text-xs leading-relaxed">
                          El servidor lleva más de 2 minutos sin reportar avance. Puede estar descargando una imagen de Docker grande, o la GPU seleccionada no está disponible.<br/>
                          Puedes esperar un poco más o cancelar y probar con otra GPU.
                        </p>
                      </div>
                    </div>
                    <button
                      onClick={async () => {
                        if (!window.confirm('¿Cancelar la sesión? El servidor se destruirá si ya fue creado.')) return;
                        await supabase.from('sessions').update({ status: 'completed' }).eq('id', session.id);
                        setSession(null);
                        setProvisioningTimeout(false);
                      }}
                      className="w-full py-2.5 bg-amber-500/10 hover:bg-amber-500/20 border border-amber-500/30 text-amber-300 rounded-lg font-bold uppercase tracking-widest text-xs transition-all flex items-center justify-center gap-2"
                    >
                      <span className="material-symbols-outlined text-sm">cancel</span>
                      CANCELAR Y PROBAR OTRA GPU
                    </button>
                  </div>
                )}
                {/* Barra de progreso de etapas */}
                <div className="flex items-center gap-2 px-1">
                  {[
                    { key: 'pending',      label: 'Solicitando' },
                    { key: 'provisioning', label: 'Instalando'  },
                    { key: 'loading_save', label: 'Cargando'    },
                    { key: 'playing',      label: 'Listo'       },
                  ].map((stage, idx, arr) => {
                    const order = ['pending','provisioning','loading_save','playing'];
                    const currentIdx = order.indexOf(session.status);
                    const stageIdx   = order.indexOf(stage.key);
                    const done    = stageIdx < currentIdx;
                    const active  = stageIdx === currentIdx;
                    return (
                      <>
                        <div key={stage.key} className="flex flex-col items-center gap-1">
                          <div className={`w-3 h-3 rounded-full border-2 transition-all duration-500 ${
                            done   ? 'bg-primary border-primary' :
                            active ? 'bg-primary/40 border-primary animate-pulse' :
                                     'bg-surface-variant border-outline-variant'
                          }`}/>
                          <span className={`text-[9px] font-label-caps tracking-widest ${
                            done || active ? 'text-primary' : 'text-on-surface-variant'
                          }`}>{stage.label}</span>
                        </div>
                        {idx < arr.length - 1 && (
                          <div className={`flex-1 h-[2px] mb-4 rounded transition-all duration-500 ${
                            stageIdx < currentIdx ? 'bg-primary' : 'bg-surface-variant'
                          }`}/>
                        )}
                      </>
                    );
                  })}
                </div>

                {/* Botones de control en carga */}
                <div className="mt-6 flex flex-wrap items-center justify-center gap-4">
                  <button
                    onClick={handleRetryInstallation}
                    className="px-5 py-2.5 bg-gradient-to-r from-violet-600 to-indigo-600 hover:from-violet-500 hover:to-indigo-500 text-white rounded-xl font-label-caps tracking-widest text-[11px] flex items-center justify-center gap-2 transition-all shadow-[0_0_15px_rgba(139,92,246,0.3)] hover:shadow-[0_0_20px_rgba(139,92,246,0.5)] transform hover:-translate-y-0.5 active:translate-y-0"
                  >
                    <span className="material-symbols-outlined text-[16px] animate-spin" style={{ animationDuration: '3s' }}>build</span>
                    REINTENTAR / REPARAR INSTALACIÓN
                  </button>

                  <button
                    onClick={async () => {
                      if (!window.confirm('¿Estás seguro de que deseas cancelar la sesión? La máquina se está creando en los servidores de TensorDock (tarda de 2 a 4 minutos). Si cancelas ahora, se perderá el progreso y la máquina virtual se eliminará.')) return;
                      await supabase.from('sessions').update({ status: 'completed' }).eq('id', session.id);
                      setSession(null);
                    }}
                    className="text-secondary hover:text-red-400 font-label-caps tracking-widest text-[11px] flex items-center justify-center gap-2 transition-colors border border-transparent hover:border-red-500/30 rounded-lg px-4 py-2 hover:bg-red-500/10"
                  >
                    <span className="material-symbols-outlined text-[16px]">cancel</span>
                    CANCELAR SESIÓN
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    );
  };

  return (
    <div className="bg-background text-on-background font-body-base overflow-x-hidden min-h-screen selection:bg-primary-container selection:text-on-primary-container">

      {/* ── MODAL UNIFICADO: STEAM AUTH (aparece cuando la VM lo solicita) ── */}
      {showSteamModal && (
        <div className="fixed inset-0 z-[110] flex items-center justify-center p-4"
             style={{background: 'rgba(0,0,0,0.90)', backdropFilter: 'blur(16px)'}}>
          <div className="w-full max-w-sm rounded-2xl border border-white/10 shadow-[0_0_80px_rgba(102,192,244,0.25)] overflow-hidden"
               style={{background: 'linear-gradient(135deg, #1b2838 0%, #0d1117 100%)'}}>

            {/* Header */}
            <div className="p-6 border-b border-white/10 flex items-center gap-3">
              <span className="text-3xl">{steamWaitMode === '2fa' ? '🔐' : '🎮'}</span>
              <div className="flex-1">
                <h2 className="text-white font-bold text-lg leading-none">
                  {steamWaitMode === '2fa' ? 'Steam Guard — 2FA' : 'Iniciar sesión en Steam'}
                </h2>
                <p className="text-[#66c0f4] text-xs mt-1">
                  {steamWaitMode === '2fa'
                    ? 'Tu servidor está listo, solo falta verificar'
                    : 'La VM necesita tus credenciales para descargar el juego'}
                </p>
              </div>
            </div>

            {/* Body */}
            <div className="p-6 space-y-4">

              {/* Mensaje de la VM */}
              {session?.status_message && (
                <div className="px-3 py-2 rounded-lg bg-[#66c0f4]/10 border border-[#66c0f4]/20">
                  <p className="text-[#66c0f4] text-xs">{session.status_message}</p>
                </div>
              )}

              {/* ── MODO: CREDENCIALES ── */}
              {steamWaitMode === 'credentials' && (<>
                <div>
                  <label className="block text-[10px] uppercase tracking-widest text-gray-400 mb-2">
                    Usuario de Steam
                  </label>
                  <input
                    id="steam-username-input"
                    type="text"
                    autoComplete="username"
                    autoFocus
                    value={steamCredentials.username}
                    onChange={e => setSteamCredentials(p => ({...p, username: e.target.value}))}
                    onKeyDown={e => e.key === 'Enter' && handleSteamCredentialsSubmit()}
                    placeholder="tu_usuario"
                    className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-3 text-white text-sm outline-none focus:border-[#66c0f4]/50 focus:shadow-[0_0_15px_rgba(102,192,244,0.15)] transition-all placeholder:text-gray-600"
                  />
                </div>
                <div>
                  <label className="block text-[10px] uppercase tracking-widest text-gray-400 mb-2">
                    Contraseña de Steam
                  </label>
                  <input
                    id="steam-password-input"
                    type="password"
                    autoComplete="current-password"
                    value={steamCredentials.password}
                    onChange={e => setSteamCredentials(p => ({...p, password: e.target.value}))}
                    onKeyDown={e => e.key === 'Enter' && handleSteamCredentialsSubmit()}
                    placeholder="••••••••"
                    className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-3 text-white text-sm outline-none focus:border-[#66c0f4]/50 focus:shadow-[0_0_15px_rgba(102,192,244,0.15)] transition-all placeholder:text-gray-600"
                  />
                </div>
                <div className="flex items-center gap-3 px-1">
                  <label className="relative inline-flex items-center cursor-pointer">
                    <input
                      type="checkbox"
                      className="sr-only peer"
                      checked={rememberSteam}
                      onChange={e => setRememberSteam(e.target.checked)}
                    />
                    <div className="w-9 h-5 bg-white/10 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-gray-300 after:border-gray-300 after:border after:rounded-full after:h-4 after:w-4 after:transition-all peer-checked:bg-[#1a9fff]"></div>
                    <span className="ml-3 text-[11px] font-medium text-gray-400 uppercase tracking-widest">Recordar credenciales</span>
                  </label>
                </div>
                <p className="text-gray-600 text-[10px] leading-relaxed">
                  🔒 Tus credenciales se envían directamente a tu servidor dedicado y se eliminan al terminar la sesión.
                </p>
              </>)}

              {/* ── MODO: 2FA ── */}
              {steamWaitMode === '2fa' && (<>
                <div className="px-3 py-2 rounded-xl bg-[#66c0f4]/10 border border-[#66c0f4]/20 text-center">
                  <p className="text-[#66c0f4] text-xs font-medium">
                    📱 Abre la app Steam Guard en tu teléfono y copia el código de 5 letras.
                  </p>
                </div>
                <div>
                  <label className="block text-[10px] uppercase tracking-widest text-gray-400 mb-2">
                    Código Steam Guard
                  </label>
                  <input
                    id="steam-2fa-input"
                    type="text"
                    autoFocus
                    maxLength={8}
                    value={steamAuthCode}
                    onChange={e => setSteamAuthCode(e.target.value.toUpperCase())}
                    onKeyDown={e => e.key === 'Enter' && handleSteam2FASubmit()}
                    placeholder="XXXXX"
                    className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-3 text-white text-center text-xl font-mono tracking-[0.4em] outline-none focus:border-[#66c0f4]/50 focus:shadow-[0_0_15px_rgba(102,192,244,0.15)] transition-all placeholder:text-gray-600"
                  />
                </div>
              </>)}

              {/* Spinner de envío */}
              {steamSubmitting && (
                <div className="flex items-center justify-center gap-2 py-2">
                  <svg className="animate-spin h-5 w-5 text-[#66c0f4]" fill="none" viewBox="0 0 24 24">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8z"/>
                  </svg>
                  <span className="text-[#66c0f4] text-sm">Enviando a tu servidor...</span>
                </div>
              )}

              {/* Error */}
              {steamError && (
                <p className="text-red-400 text-xs bg-red-500/10 border border-red-500/20 rounded-lg px-3 py-2">
                  {steamError}
                </p>
              )}
            </div>

            {/* Footer */}
            {!steamSubmitting && (
              <div className="p-6 pt-0 flex gap-3">
                <button
                  onClick={async () => {
                    if (preLaunchGameId) {
                      setShowSteamModal(false);
                      setPreLaunchGameId(null);
                      return;
                    }
                    if (!window.confirm('¿Estás seguro de que deseas cancelar la sesión? El servidor dedicado ya está encendido. Si cancelas ahora, la máquina virtual se destruirá automáticamente.')) return;
                    await supabase.from('sessions').update({ status: 'completed' }).eq('id', session.id);
                    setSession(null);
                    setShowSteamModal(false);
                  }}
                  className="px-4 py-2 rounded-lg bg-white/5 border border-white/10 hover:bg-red-500/10 hover:border-red-500/30 hover:text-red-400 text-gray-400 font-bold uppercase tracking-widest text-xs transition-all flex-1"
                >
                  Cancelar
                </button>
                <button
                  onClick={steamWaitMode === '2fa' ? handleSteam2FASubmit : handleSteamCredentialsSubmit}
                  className="px-4 py-2 rounded-lg bg-[#1a9fff] hover:bg-[#66c0f4] text-white font-bold uppercase tracking-widest text-xs transition-all flex-1 shadow-[0_0_15px_rgba(102,192,244,0.3)] hover:shadow-[0_0_25px_rgba(102,192,244,0.5)]"
                >
                  {steamWaitMode === '2fa' ? 'Verificar' : 'Continuar'}
                </button>
              </div>
            )}
          </div>
        </div>
      )}


      <header className="fixed top-0 w-full h-16 z-50 flex items-center justify-between px-6 bg-[#050505]/90 backdrop-blur-2xl border-b border-[#262626] shadow-[0_4px_20px_rgba(139,92,246,0.1)]">
        <div className="flex items-center gap-container-margin">
          <button className="md:hidden text-on-surface hover:text-primary transition-colors">
            <span className="material-symbols-outlined">menu</span>
          </button>
          <div className="text-xl font-black italic tracking-tighter text-white font-inter">AETHER CLOUD</div>
        </div>
        <div className="hidden md:flex flex-1 max-w-md mx-container-margin relative group">
          <span className="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-on-surface-variant group-focus-within:text-primary transition-colors">search</span>
          <input className="w-full bg-surface-container border-outline-variant text-on-surface rounded-full py-2 pl-10 pr-4 focus:border-primary focus:ring-1 focus:ring-primary focus:shadow-[0_0_15px_rgba(139,92,246,0.3)] transition-all outline-none placeholder:text-on-surface-variant text-body-sm" placeholder="Search games, genres..." type="text"/>
        </div>
        <div className="flex items-center gap-stack-md text-on-surface-variant">
          {userData?.is_admin && (
            <button onClick={() => setIsAdminView(true)} className="hover:text-primary transition-colors flex items-center gap-1 font-label-caps tracking-widest text-[10px] border border-outline-variant rounded-full px-3 py-1">
              <span className="material-symbols-outlined text-sm">shield</span> ADMIN
            </button>
          )}
          <div className="h-4 w-[1px] bg-outline-variant mx-1"></div>
          <div className="flex flex-col items-end mr-2">
            <span className="text-[10px] font-bold text-white tracking-tighter truncate max-w-[120px]">{authSession.user.email}</span>
            <button onClick={handleLogout} className="text-[9px] text-violet-400 hover:text-white uppercase tracking-widest font-black transition-colors">CERRAR SESIÓN</button>
          </div>
          <div className="w-8 h-8 rounded-full overflow-hidden border border-primary/50 shadow-[0_0_10px_rgba(139,92,246,0.3)]">
            <img alt="User profile" className="w-full h-full object-cover" src={`https://api.dicebear.com/7.x/bottts/svg?seed=${authSession.user.id}`}/>
          </div>
        </div>
      </header>

      {/* SideNavBar */}
      <nav className="hidden md:flex fixed left-0 top-16 h-[calc(100vh-64px)] w-64 flex-col py-6 z-40 bg-[#121212]/95 backdrop-blur-md border-r border-[#262626] shadow-2xl">
        <div className="px-6 mb-stack-lg flex flex-col">
          <h2 className="font-label-caps text-on-surface-variant mb-1 tracking-widest text-xs">Pro Gaming</h2>
          <p className={activeServers >= 8 ? "font-body-sm text-error flex items-center gap-1" : "font-body-sm text-primary flex items-center gap-1"}>
            <span className="material-symbols-outlined text-sm" style={{fontVariationSettings: "'FILL' 1"}}>check_circle</span> 
            {activeServers}/8 Servers Used
          </p>
        </div>
        <div className="flex-1 flex flex-col gap-1 px-3">
          <a className="flex items-center gap-3 bg-violet-600/20 text-white border-r-4 border-violet-500 px-4 py-3 rounded-r-lg hover:bg-[#1E1E1E] transition-all duration-200 font-inter text-sm font-semibold" href="#">
            <span className="material-symbols-outlined text-[20px]" style={{fontVariationSettings: "'FILL' 1"}}>sports_esports</span>
            Library
          </a>
          <a className="flex items-center gap-3 text-gray-500 px-4 py-3 hover:text-gray-200 hover:bg-[#1E1E1E] rounded-lg transition-all duration-200 font-inter text-sm font-semibold" href="#">
            <span className="material-symbols-outlined text-[20px]">explore</span>
            Explore
          </a>
        </div>
        <div className="px-6 mt-auto">
          <button className="w-full py-2 mb-stack-md bg-transparent border border-primary text-primary hover:bg-primary/10 rounded font-label-caps tracking-widest text-xs transition-colors">
            UPGRADE TO 4K
          </button>
        </div>
      </nav>

      {/* Main Content Canvas */}
      <main className="pt-16 md:pl-64 min-h-screen pb-section-gap relative">
        {error && (
          <div className="absolute top-20 left-1/2 -translate-x-1/2 z-50 bg-error-container border border-error text-on-error-container px-6 py-3 rounded-lg shadow-lg flex items-center gap-2">
            <span className="material-symbols-outlined">error</span>
            {error}
          </div>
        )}

        {session && session.status !== 'completed' ? (
           renderActiveSession()
        ) : (
          <>
            {/* Hero Section */}
            <section className="relative h-[400px] xl:h-[614px] w-full flex items-end p-container-margin md:p-section-gap overflow-hidden">
              <div className="absolute inset-0 z-0">
                <div className="absolute inset-0 bg-gradient-to-t from-background via-background/80 to-transparent z-10"></div>
                <div className="absolute inset-0 bg-gradient-to-r from-background via-background/50 to-transparent z-10"></div>
                {games.length > 0 && games[0].image_url ? (
                  <img alt="Hero Game" className="w-full h-full object-cover" src={games[0].image_url} />
                ) : (
                  <div className="w-full h-full bg-surface-container"></div>
                )}
              </div>
              
              <div className="relative z-20 max-w-3xl glass-panel p-stack-lg rounded-xl">
                <span className="inline-block px-3 py-1 bg-primary/20 text-primary border border-primary/30 rounded-full font-label-caps tracking-widest text-[10px] mb-stack-sm backdrop-blur-sm">FEATURED</span>
                <h1 className="font-display-lg text-on-surface mb-unit">{games.length > 0 ? games[0].name : 'Cyberpunk 2077'}</h1>
                <p className="font-body-base text-on-surface-variant mb-stack-lg max-w-xl">
                  {games.length > 0 ? games[0].description : 'Immerse yourself in the gritty underworld. Play instantly from the cloud.'}
                </p>
                <div className="flex items-center gap-stack-sm">
                  {games.length > 0 && (
                    <button 
                      onClick={() => handlePlay(games[0].id)}
                      disabled={loading || isServerFull}
                      className="bg-primary text-on-primary font-title-lg px-8 py-3 rounded-lg flex items-center gap-2 hover:bg-primary-fixed hover:bloom-shadow transition-all duration-300 disabled:opacity-50"
                    >
                      <span className="material-symbols-outlined" style={{fontVariationSettings: "'FILL' 1"}}>play_arrow</span>
                      Play Now
                    </button>
                  )}
                </div>
              </div>
            </section>

            {/* Game Grid Section */}
            <section className="px-container-margin md:px-section-gap mt-stack-lg relative z-10">
              <div className="flex items-center justify-between mb-stack-lg">
                <h2 className="font-headline-md text-on-surface">Available Games</h2>
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-gutter">
                {games.map((game, i) => (
                  <div key={game.id} onClick={() => !loading && !isServerFull && handlePlay(game.id)} className="group relative rounded-xl border border-outline-variant bg-surface-container overflow-hidden hover:scale-[1.05] hover:border-primary/50 hover:shadow-[0_4px_20px_rgba(139,92,246,0.2)] transition-all duration-300 cursor-pointer">
                    <div className="aspect-[16/9] overflow-hidden relative">
                      {game.image_url ? (
                        <img alt={game.name} className="w-full h-full object-cover group-hover:scale-110 transition-transform duration-500" src={game.image_url} />
                      ) : (
                        <div className="w-full h-full flex items-center justify-center bg-surface-variant text-on-surface-variant font-title-lg">{game.name}</div>
                      )}
                      <div className="absolute inset-0 bg-gradient-to-t from-surface-container via-transparent to-transparent"></div>
                      <div className="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity duration-300 flex items-center justify-center backdrop-blur-sm">
                        <button disabled={loading || isServerFull} className="bg-primary text-on-primary rounded-full p-4 hover:scale-110 transition-transform bloom-shadow disabled:bg-surface-variant">
                          <span className="material-symbols-outlined text-[32px]" style={{fontVariationSettings: "'FILL' 1"}}>play_arrow</span>
                        </button>
                      </div>
                    </div>
                    <div className="p-container-margin relative z-10 bg-surface-container">
                      <h3 className="font-title-lg text-on-surface mb-1">{game.name}</h3>
                      <p className="font-body-sm text-on-surface-variant mb-stack-sm">{game.genre || 'Action'}</p>
                      {/* Fake Progress */}
                      <div className="w-full h-1 bg-surface-variant rounded-full overflow-hidden mb-stack-sm">
                        <div className="h-full bg-primary rounded-full" style={{width: `${(i + 1) * 20}%`}}></div>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </section>
          </>
        )}
      </main>
    </div>
  )
}

export default App
