import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'brand.dart';
export 'brand.dart' show ink, accent;

import 'domain.dart';
import 'repository.dart';
import 'scan_label.dart';
import 'product_form.dart';
import 'sale_page.dart';

class LineboardApp extends StatelessWidget {
  const LineboardApp({super.key, this.repository});
  final Repository? repository;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Lineboard',
    debugShowCheckedModeBanner: false,
    theme: lineboardTheme(),
    home: repository == null ? const SetupPage() : SessionGate(repository!),
  );
}

class SetupPage extends StatelessWidget {
  const SetupPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StoreLogo(size: 120),
              SizedBox(height: 24),
              Text(
                'Lineboard',
                style: TextStyle(
                  fontSize: 36,
                  color: ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 12),
              Text(
                'Este aplicativo ainda precisa ser conectado à sua loja.',
                style: TextStyle(fontSize: 20),
              ),
              SizedBox(height: 16),
              Text(
                'Configure o projeto Supabase e as chaves públicas de compilação conforme o README do projeto.',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class SessionGate extends StatefulWidget {
  const SessionGate(this.repo, {super.key});
  final Repository repo;
  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  StreamSubscription<AuthState>? subscription;
  Repository? activeRepository;
  @override
  void initState() {
    super.initState();
    subscription = widget.repo.client.auth.onAuthStateChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.repo.client.auth.currentUser;
    if (user == null) {
      activeRepository = null;
      return LoginPage(widget.repo);
    }
    if (activeRepository?.userId != user.id) {
      activeRepository = widget.repo.forCurrentSession();
    }
    return OrganizationPage(activeRepository!, key: ValueKey(user.id));
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage(this.repo, {super.key});
  final Repository repo;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final token = TextEditingController();
  bool sent = false, busy = false;
  String? error;
  @override
  void dispose() {
    email.dispose();
    token.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (email.text.trim().isEmpty || (sent && token.text.trim().isEmpty)) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!sent) {
        await widget.repo.client.auth.signInWithOtp(
          email: email.text.trim(),
          shouldCreateUser: false,
          emailRedirectTo: 'io.lineboard.mobile://login-callback',
        );
        if (mounted) setState(() => sent = true);
      } else {
        try {
          await widget.repo.client.auth.verifyOTP(
            email: email.text.trim(),
            token: token.text.trim(),
            type: OtpType.email,
          );
        } on AuthException {
          await widget.repo.client.auth.verifyOTP(
            email: email.text.trim(),
            token: token.text.trim(),
            type: OtpType.invite,
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: StoreLogo(size: 132),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Da etiqueta\nà próxima onda.',
                  style: TextStyle(
                    fontSize: 36,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Acesse com o e-mail convidado pela sua loja.'),
                const SizedBox(height: 28),
                TextField(
                  controller: email,
                  enabled: !busy && !sent,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'E-mail da equipe',
                  ),
                ),
                if (sent) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: token,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    decoration: const InputDecoration(
                      labelText: 'Código recebido por e-mail',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Você também pode abrir o link do e-mail neste celular.',
                  ),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(
                    busy
                        ? 'Aguarde…'
                        : sent
                        ? 'Entrar'
                        : 'Receber acesso',
                  ),
                ),
                if (sent)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            sent = false;
                            token.clear();
                          }),
                    child: const Text('Usar outro e-mail ou reenviar'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class OrganizationPage extends StatefulWidget {
  const OrganizationPage(this.repo, {super.key});
  final Repository repo;
  @override
  State<OrganizationPage> createState() => _OrganizationPageState();
}

class _OrganizationPageState extends State<OrganizationPage> {
  late Future<List<Map<String, dynamic>>> future;
  @override
  void initState() {
    super.initState();
    future = widget.repo.memberships();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.hasData && snapshot.data!.length == 1) {
        return HomePage(widget.repo, snapshot.data!.single);
      }
      return Scaffold(
        appBar: AppBar(
          title: const Text('Suas lojas'),
          actions: [
            IconButton(
              onPressed: widget.repo.logout,
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: !snapshot.hasData && !snapshot.hasError
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (snapshot.hasError) Text(friendlyError(snapshot.error!)),
                  if (snapshot.hasData && snapshot.data!.isEmpty)
                    const Text(
                      'Nenhuma loja vinculada. Peça um convite ao administrador.',
                    ),
                  for (final member
                      in snapshot.data ?? <Map<String, dynamic>>[])
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.storefront),
                        title: Text(member['organizations']['name']),
                        subtitle: Text(
                          member['role'] == 'admin'
                              ? 'Administrador'
                              : 'Operador',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => HomePage(widget.repo, member),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () =>
                        setState(() => future = widget.repo.memberships()),
                    child: const Text('Atualizar acesso'),
                  ),
                ],
              ),
      );
    },
  );
}

class HomePage extends StatefulWidget {
  const HomePage(this.repo, this.member, {super.key});
  final Repository repo;
  final Map<String, dynamic> member;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool syncing = false;
  String? status;
  String get org => widget.member['organization_id'];
  @override
  void initState() {
    super.initState();
    sync();
  }

  Future<void> sync() async {
    setState(() => syncing = true);
    try {
      await widget.repo.syncCatalog(org);
      if (mounted) setState(() => status = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => status = 'Sem sincronização. As fichas salvas podem estar desatualizadas. Cadastros e saídas precisam de internet.',
        );
      }
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  Future<void> identify() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null || !mounted) return;
    CatalogItem? item;
    bool cached = false;
    try {
      item = await widget.repo.lookup(org, code);
    } catch (e) {
      // A definitive server "not found" must never be replaced by stale cache.
      if (e is! StateError && e is! PostgrestException) {
        final matches = widget.repo
            .cachedCatalog(org)
            .where((i) => i.barcode == code);
        if (matches.isNotEmpty) {
          item = matches.first;
          cached = true;
        }
      }
      if (item == null && mounted) toast(context, friendlyError(e));
    }
    if (item != null && mounted) {
      await open(LabelPage(item, repo: widget.repo, offline: cached));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingProduct = widget.repo.pendingProduct(org);
    final pendingSale = widget.repo.pendingSale(org);
    final lastSync = widget.repo.syncTime(org)?.toLocal();
    return Scaffold(
      appBar: AppBar(
        title: const StoreAppBarTitle(),
        actions: [
          if (widget.member['role'] == 'admin')
            IconButton(
              tooltip: 'Convidar equipe',
              onPressed: () => open(InvitePage(widget.repo, org)),
              icon: const Icon(Icons.person_add_alt),
            ),
          IconButton(
            tooltip: 'Sair',
            onPressed: widget.repo.logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Text(
            widget.member['organizations']['name'],
            style: const TextStyle(color: accent, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const Text(
            'Pronto para\na próxima saída.',
            style: TextStyle(
              fontSize: 36,
              height: 1.1,
              color: ink,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Cadastre, etiquete e registre a venda física. Tudo conectado à sua loja.',
          ),
          const SizedBox(height: 28),
          if (pendingSale != null)
            Card(
              color: const Color(0xFFEBEBEB),
              child: ListTile(
                title: const Text('Saída aguardando confirmação'),
                subtitle: const Text(
                  'Retome para conferir o resultado sem duplicar a baixa.',
                ),
                trailing: const Icon(Icons.arrow_forward),
                onTap: () => open(SalePage(widget.repo, org)),
              ),
            ),
          if (pendingProduct != null)
            Card(
              color: const Color(0xFFEBEBEB),
              child: ListTile(
                title: const Text('Cadastro aguardando confirmação'),
                subtitle: Text(pendingProduct['product']['name']),
                trailing: const Icon(Icons.arrow_forward),
                onTap: () => open(ProductForm(widget.repo, org)),
              ),
            ),
          ActionCard(
            icon: Icons.barcode_reader,
            title: 'Registrar saída',
            subtitle:
                'Envie as peças ao carrinho da loja e confirme no desktop.',
            primary: true,
            onTap: () => open(SalePage(widget.repo, org)),
          ),
          ActionCard(
            icon: Icons.add_box_outlined,
            title: 'Cadastrar produto',
            subtitle: 'Crie variantes e gere as etiquetas da loja.',
            onTap: () => open(ProductForm(widget.repo, org)),
          ),
          ActionCard(
            icon: Icons.document_scanner_outlined,
            title: 'Identificar / reimprimir',
            subtitle: 'Leia um código para abrir a ficha e a etiqueta.',
            onTap: identify,
          ),
          const SizedBox(height: 20),
          if (status != null)
            Text(status!, style: const TextStyle(color: Color(0xFF626262))),
          Text(
            lastSync == null
                ? 'Nenhuma ficha salva para uso offline.'
                : 'Fichas salvas em ${lastSync.day}/${lastSync.month} às ${lastSync.hour.toString().padLeft(2, '0')}:${lastSync.minute.toString().padLeft(2, '0')}.',
            style: const TextStyle(fontSize: 12),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: syncing ? null : sync,
              icon: const Icon(Icons.sync),
              label: Text(
                syncing ? 'Sincronizando fichas…' : 'Atualizar fichas offline',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool primary;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    color: primary ? ink : Colors.white,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            Icon(
              icon,
              size: 32,
              color: primary ? const Color(0xFFFFFFFF) : accent,
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: primary ? Colors.white : ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: primary ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: primary ? Colors.white : ink),
          ],
        ),
      ),
    ),
  );
}

class InvitePage extends StatefulWidget {
  const InvitePage(this.repo, this.org, {super.key});
  final Repository repo;
  final String org;
  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  final email = TextEditingController();
  String role = 'operator';
  bool busy = false;
  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> invite() async {
    setState(() => busy = true);
    try {
      await widget.repo.client.functions.invoke(
        'invite-member',
        body: {
          'organization_id': widget.org,
          'email': email.text.trim(),
          'role': role,
        },
      );
      if (mounted) {
        toast(context, 'Convite enviado por e-mail.');
        email.clear();
      }
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Convidar equipe')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Cada pessoa usa seu próprio acesso à loja.'),
        const SizedBox(height: 24),
        TextField(
          controller: email,
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'E-mail'),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: role,
          decoration: const InputDecoration(labelText: 'Permissão'),
          items: const [
            DropdownMenuItem(value: 'operator', child: Text('Operador')),
            DropdownMenuItem(value: 'admin', child: Text('Administrador')),
          ],
          onChanged: busy ? null : (v) => setState(() => role = v!),
        ),
        const SizedBox(height: 12),
        const Text(
          'Operadores cadastram e registram saídas. Administradores também convidam pessoas e gerenciam integrações.',
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: busy ? null : invite,
          child: Text(busy ? 'Enviando…' : 'Enviar convite'),
        ),
      ],
    ),
  );
}

void toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
