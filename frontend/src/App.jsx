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
  // Estado de la UI
  const [preLaunchGameId, setPreLaunchGameId] = useState(null)
  const [tailscaleAuthKey, setTailscaleAuthKey] = useState('')
  const [showSettingsModal, setShowSettingsModal] = useState(false)
  const [settingsSubmitting, setSettingsSubmitting] = useState(false)
  const [settingsError, setSettingsError] = useState(null)
  
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
    setUserData(data)
    if (data?.metadata?.tailscale_authkey) {
      setTailscaleAuthKey(data.metadata.tailscale_authkey)
    }
  }

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
    let pollInterval = null;
    // Cronómetro activo en todos los estados de espera/instalación
    const waitingStatuses = ['pending', 'provisioning', 'loading_save', 'waiting_steam_auth'];
    if (session && waitingStatuses.includes(session.status)) {
      interval = setInterval(() => {
        setElapsedSeconds(prev => prev + 1);
      }, 1000);
      
      // Fallback: Consultar a la base de datos cada 10 segundos por si el socket se desconecta
      pollInterval = setInterval(() => {
        checkActiveSession();
      }, 10000);
    } else {
      setElapsedSeconds(0);
      if (interval) clearInterval(interval);
      if (pollInterval) clearInterval(pollInterval);
    }
    return () => {
      if (interval) clearInterval(interval);
      if (pollInterval) clearInterval(pollInterval);
    };
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

  // NOTA: Eliminado el handler 'beforeunload' que mataba la sesión al recargar.
  // El pod solo se termina cuando el usuario hace clic en el botón "Detener" explícitamente.
  // Si el usuario recarga o cierra accidentalmente, la sesión se reconecta automáticamente
  // gracias a checkActiveSession() que corre al iniciar la app.


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
      .in('status', ['pending', 'provisioning', 'loading_save', 'playing', 'running', 'waiting_steam_auth', 'failed'])
      .limit(1)
      
    if (data && data.length > 0) {
      setSession(data[0])
    }
  }

  const fetchActiveServersCount = async () => {
    const { count, error } = await supabase
      .from('sessions')
      .select('*', { count: 'exact', head: true })
      .in('status', ['pending', 'provisioning', 'loading_save', 'playing', 'running'])
    
    if (!error && count !== null) {
      setActiveServers(count)
    }
  }

  // Crear sesión — siempre con SESSION_ID fresco
  const handlePlay = async (gameId) => {
    if (activeServers >= 8 || !authSession || loading) return

    // Pre-launch credentials check
    if (!tailscaleAuthKey) {
      setShowSettingsModal(true)
      return
    }

    // Bloquear botón inmediatamente para evitar doble-click
    setLoading(true)
    setError(null)
    setProvisioningTimeout(false)

    try {
      // Limpiar TODAS las sesiones anteriores de este usuario
      // para garantizar un SESSION_ID fresco y que el orquestador elimine pods huerfanos.
      await supabase
        .from('sessions')
        .update({ status: 'completed' })
        .eq('user_id', authSession.user.id)
        .in('status', ['pending', 'provisioning', 'loading_save', 'playing', 'running', 'waiting_steam_auth', 'failed'])

      const { data, error: rpcErr } = await supabase.rpc('allocate_game_session', {
        p_game_id: gameId,
        p_user_id: authSession.user.id
      })
      if (rpcErr) throw rpcErr
      const sessionId = data[0].session_id

      // Update session with credentials immediately
      await supabase.from('sessions').update({
        tailscale_authkey: tailscaleAuthKey
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

  const handleSettingsSubmit = async () => {
    setSettingsSubmitting(true)
    setSettingsError(null)
    try {
      const { error } = await supabase
        .from('users')
        .update({ 
          metadata: { ...userData?.metadata, tailscale_authkey: tailscaleAuthKey } 
        })
        .eq('id', authSession.user.id)
      if (error) throw error
      setUserData(prev => ({ ...prev, metadata: { ...prev?.metadata, tailscale_authkey: tailscaleAuthKey } }))
      setShowSettingsModal(false)
    } catch (err) {
      setSettingsError('Error al guardar: ' + err.message)
    } finally {
      setSettingsSubmitting(false)
    }
  }

  const [moonlightPin, setMoonlightPin] = useState('')
  const [pairingLoading, setPairingLoading] = useState(false)
  // pinSent persiste en sessionStorage para sobrevivir recargas dentro de la misma sesión
  const [pinSent, setPinSent] = useState(() => {
    try { return sessionStorage.getItem('pinSent') === 'true' } catch { return false }
  })
  const [pinCountdown, setPinCountdown] = useState(0)
  const [pinPaired, setPinPaired] = useState(false)

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
      setPinSent(true)
      try { sessionStorage.setItem('pinSent', 'true') } catch {}

      // Cuenta regresiva de 4s para que Sunshine autorice el dispositivo
      let count = 4
      setPinCountdown(count)
      const countdown = setInterval(() => {
        count -= 1
        setPinCountdown(count)
        if (count <= 0) {
          clearInterval(countdown)
          // Refrescar sesión para ver si el orquestador ya confirmó el emparejamiento
          checkActiveSession()
        }
      }, 1000)

      // Polling cada 3s durante 30s para detectar cuándo el orquestador limpió el PIN
      let pollCount = 0
      const pollPaired = setInterval(async () => {
        pollCount++
        const { data } = await supabase
          .from('sessions')
          .select('moonlight_pin')
          .eq('id', session.id)
          .single()
        // El orquestador borra el pin a null cuando lo procesa con éxito
        if (data && (data.moonlight_pin === null || data.moonlight_pin === '')) {
          setPinPaired(true)
          clearInterval(pollPaired)
          try { sessionStorage.removeItem('pinSent') } catch {}
        }
        if (pollCount >= 10) clearInterval(pollPaired)
      }, 3000)
    } catch (err) {
      alert('Error al enviar el PIN: ' + err.message)
    } finally {
      setPairingLoading(false)
    }
  }

  const handleDestroySession = async () => {
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

  const handleSleepSession = async () => {
    if (!session) return;
    setLoading(true)
    try {
      const { error } = await supabase
        .from('sessions')
        .update({ status: 'sleeping_requested' })
        .eq('id', session.id)

      if (error) throw error
      // The local status will update via Realtime, but we can set it locally for faster UI
      setSession(prev => ({ ...prev, status: 'sleeping_requested' }))
    } catch (err) {
      setError('Error al dormir la sesión')
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
    
    // RunPod public IP (almacenada como ip_address tras bootstrap SSH)
    const connectIp = session.tailscale_ip || session.ip_address
      || (session.status_message && session.status_message.match(/[\d]{1,3}\.[\d]{1,3}\.[\d]{1,3}\.[\d]{1,3}/)?.[0]);
    const extractedIp = connectIp;
    
    if (session.status === 'playing' || session.status === 'running') {
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
                onClick={handleSleepSession}
                title="Pausa el servidor. El juego iniciará rápido la próxima vez, pero RunPod cobrará por el almacenamiento ($0.15/día aprox)."
                className="text-white font-inter font-bold uppercase tracking-widest text-[10px] py-1.5 px-3 rounded-full hover:bg-yellow-500/20 hover:text-yellow-400 transition-colors flex items-center gap-1 border border-transparent hover:border-yellow-500/30"
              >
                  <span className="material-symbols-outlined text-[14px]">bedtime</span>
                  DORMIR SERVIDOR
              </button>
              <button 
                onClick={handleDestroySession}
                title="Elimina el servidor por completo. No se cobrará nada, pero la próxima sesión requerirá reinstalar."
                className="text-white font-inter font-bold uppercase tracking-widest text-[10px] py-1.5 px-3 rounded-full hover:bg-red-500/20 hover:text-red-400 transition-colors flex items-center gap-1 border border-transparent hover:border-red-500/30"
              >
                  <span className="material-symbols-outlined text-[14px]">delete</span>
                  DESTRUIR SERVIDOR
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
                <p className="text-emerald-400 text-[10px] font-bold uppercase tracking-widest mb-1">Abre Moonlight y agrega esta IP de Tailscale:</p>
                <code className="text-[#FF4500] font-mono text-xl block mt-2">{extractedIp}</code>
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

              {pinPaired ? (
                <div className="w-full bg-emerald-500/10 border border-emerald-500/30 rounded-xl p-4 mt-4 flex flex-col items-center gap-3">
                  <p className="text-emerald-400 font-bold text-sm flex items-center gap-2">
                    <span className="material-symbols-outlined text-[18px]" style={{fontVariationSettings: "'FILL' 1"}}>verified</span>
                    ¡Dispositivo emparejado con éxito!
                  </p>
                  {session.web_url && (
                    <a
                      href={session.web_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="w-full py-3 bg-gradient-to-r from-emerald-600 to-teal-500 hover:from-emerald-500 hover:to-teal-400 text-white rounded-xl font-bold uppercase tracking-widest text-xs transition-all shadow-[0_0_20px_rgba(16,185,129,0.4)] flex items-center justify-center gap-2"
                    >
                      <span className="material-symbols-outlined text-[16px]">sports_esports</span>
                      Abrir Moonlight Web
                    </a>
                  )}
                </div>
              ) : pinSent ? (
                <div className="w-full bg-green-500/10 border border-green-500/30 rounded-xl p-4 mt-4 flex flex-col items-center gap-3">
                  <p className="text-green-400 font-bold text-sm flex items-center gap-2">
                    <span className="material-symbols-outlined text-[18px]" style={{fontVariationSettings: "'FILL' 1"}}>check_circle</span>
                    PIN Enviado — Autorizando dispositivo...
                  </p>
                  {pinCountdown > 0 ? (
                    <p className="text-gray-400 text-xs">
                      Verificando emparejamiento en <strong className="text-white">{pinCountdown}s</strong>...
                    </p>
                  ) : (
                    session.web_url && (
                      <a
                        href={session.web_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="w-full py-3 bg-gradient-to-r from-emerald-600 to-teal-500 hover:from-emerald-500 hover:to-teal-400 text-white rounded-xl font-bold uppercase tracking-widest text-xs transition-all shadow-[0_0_20px_rgba(16,185,129,0.4)] flex items-center justify-center gap-2"
                      >
                        <span className="material-symbols-outlined text-[16px]">open_in_new</span>
                        Abrir Moonlight Web
                      </a>
                    )
                  )}
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
                    <div className="font-title-lg text-primary max-h-48 overflow-y-auto whitespace-pre-wrap w-full">{session.status_message || 'Iniciando Windows y ejecutando script...'}</div>
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

            ) : session.status === 'failed' ? (
              <div className="flex flex-col items-center gap-6 p-8 rounded-2xl bg-error-container/10 border border-error/20 max-w-md w-full">
                <span className="material-symbols-outlined text-[64px] text-red-500 animate-pulse" style={{fontVariationSettings: "'FILL' 1"}}>error</span>
                <div className="text-center">
                  <h2 className="font-display-md text-white text-xl font-bold">Algo salió mal en el servidor</h2>
                  <div className="text-gray-400 text-sm mt-2 leading-relaxed max-h-64 overflow-y-auto whitespace-pre-wrap text-left p-3 bg-black/20 rounded-lg border border-white/5 w-full">{session.status_message || 'Hubo un error al preparar tu sesión.'}</div>
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
                        <div className="font-title-lg text-primary max-h-48 overflow-y-auto whitespace-pre-wrap w-full">
                          {session.status_message || 'Allocating dedicated server...'}
                        </div>
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

      {/* ── SETTINGS MODAL ── */}
      {showSettingsModal && (
        <div className="fixed inset-0 z-[100] flex items-center justify-center p-4">
          <div className="absolute inset-0 bg-black/80 backdrop-blur-sm" onClick={() => setShowSettingsModal(false)}></div>
          <div className="relative w-full max-w-md bg-[#121212] border border-white/10 rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
            <div className="p-6 border-b border-white/10 flex items-center gap-3">
              <span className="text-3xl">⚙️</span>
              <div className="flex-1">
                <h2 className="text-white font-bold text-lg leading-none">Configuración de Cuenta</h2>
                <p className="text-gray-400 text-xs mt-1">Configura tu red privada para conectarte a los servidores</p>
              </div>
            </div>
            <div className="p-6 space-y-4">
              <div>
                <label className="block text-[10px] font-bold uppercase tracking-widest text-emerald-400 mb-2">
                  Tailscale Auth Key (Red Privada)
                </label>
                <input
                  type="password"
                  value={tailscaleAuthKey}
                  onChange={e => setTailscaleAuthKey(e.target.value)}
                  placeholder="tskey-auth-..."
                  className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-3 text-white text-sm outline-none focus:border-emerald-500/50 focus:shadow-[0_0_15px_rgba(16,185,129,0.15)] transition-all placeholder:text-gray-600 mb-2"
                />
                <p className="text-gray-500 text-[10px] leading-relaxed">
                  Obtén tu Auth Key en <a href="https://login.tailscale.com/admin/settings/keys" target="_blank" rel="noreferrer" className="text-emerald-400 hover:underline">tailscale.com</a>. Esto conectará el servidor a tu propia red VPN de forma segura.
                </p>
              </div>
              
              {settingsError && (
                <p className="text-red-400 text-xs bg-red-500/10 border border-red-500/20 rounded-lg px-3 py-2">
                  {settingsError}
                </p>
              )}
            </div>
            <div className="p-6 pt-0 flex gap-3">
              <button
                onClick={() => setShowSettingsModal(false)}
                className="px-4 py-2 rounded-lg bg-white/5 border border-white/10 hover:bg-white/10 text-gray-400 font-bold uppercase tracking-widest text-xs transition-all flex-1"
              >
                Cancelar
              </button>
              <button
                onClick={handleSettingsSubmit}
                disabled={settingsSubmitting}
                className="px-4 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white font-bold uppercase tracking-widest text-xs transition-all flex-1 shadow-[0_0_15px_rgba(16,185,129,0.3)] disabled:opacity-50"
              >
                {settingsSubmitting ? 'Guardando...' : 'Guardar'}
              </button>
            </div>
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
          <button onClick={() => setShowSettingsModal(true)} className="flex items-center gap-3 text-gray-500 px-4 py-3 hover:text-gray-200 hover:bg-[#1E1E1E] rounded-lg transition-all duration-200 font-inter text-sm font-semibold text-left w-full">
            <span className="material-symbols-outlined text-[20px]" style={{fontVariationSettings: "'FILL' 1"}}>settings</span>
            Configuración
          </button>
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

        {!tailscaleAuthKey && (!session || session.status === 'completed') && (
          <div className="absolute top-0 left-0 w-full z-40 bg-red-500/90 border-b border-red-700 text-white px-6 py-2 shadow-lg flex items-center justify-center gap-2 backdrop-blur-md font-bold text-sm transition-all">
            <span className="material-symbols-outlined text-[18px]">warning</span>
            <span>¡Atención! Debes configurar tu Tailscale Auth Key en tu cuenta para poder iniciar juegos.</span>
            <button onClick={() => setShowSettingsModal(true)} className="ml-4 px-3 py-1 bg-white/20 hover:bg-white/30 rounded text-xs transition-colors shadow">Configurar</button>
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
                {games.map((game, i) => {
                  // Badge por launcher
                  const launcherConfig = {
                    steam:    { label: 'Steam',    color: 'from-[#1b2838] to-[#2a475e]', border: 'border-[#66c0f4]/40', text: 'text-[#66c0f4]', icon: '🎮' },
                    epic:     { label: 'Epic',     color: 'from-[#2d0036] to-[#0d0d0d]', border: 'border-purple-500/40', text: 'text-purple-400',   icon: '⚡' },
                    gog:      { label: 'GOG',      color: 'from-[#220000] to-[#1a0a00]', border: 'border-orange-500/40', text: 'text-orange-400',   icon: '🔮' },
                    lutris:   { label: 'Lutris',   color: 'from-[#1a1200] to-[#0d0d0d]', border: 'border-yellow-500/40', text: 'text-yellow-400',   icon: '🦅' },
                    emulator: { label: 'Emulator', color: 'from-[#001a12] to-[#0d0d0d]', border: 'border-emerald-500/40', text: 'text-emerald-400', icon: '🕹️' },
                  };
                  const launcher = launcherConfig[game.launcher] || launcherConfig.steam;

                  return (
                  <div key={game.id} onClick={() => !loading && !isServerFull && handlePlay(game.id)} className="group relative rounded-xl border border-outline-variant bg-surface-container overflow-hidden hover:scale-[1.05] hover:border-primary/50 hover:shadow-[0_4px_20px_rgba(139,92,246,0.2)] transition-all duration-300 cursor-pointer">
                    <div className="aspect-[16/9] overflow-hidden relative">
                      {game.image_url ? (
                        <img alt={game.name} className="w-full h-full object-cover group-hover:scale-110 transition-transform duration-500" src={game.image_url} />
                      ) : (
                        <div className="w-full h-full flex items-center justify-center bg-surface-variant text-on-surface-variant font-title-lg">{game.name}</div>
                      )}
                      <div className="absolute inset-0 bg-gradient-to-t from-surface-container via-transparent to-transparent"></div>
                      {/* Badge de launcher */}
                      <div className={`absolute top-2 left-2 flex items-center gap-1 px-2 py-0.5 rounded-full text-[9px] font-bold uppercase tracking-widest border backdrop-blur-sm bg-gradient-to-r ${launcher.color} ${launcher.border} ${launcher.text}`}>
                        <span>{launcher.icon}</span>
                        {launcher.label}
                      </div>
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
                  );
                })}
              </div>
            </section>
          </>
        )}
      </main>
    </div>
  )
}

export default App
