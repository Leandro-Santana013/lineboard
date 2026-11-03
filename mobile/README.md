# Lineboard Mobile

Aplicativo Flutter Android para login, cadastro e fotos de produtos, etiquetas
Code 128 e leitura para o caixa. O APK inclui o aplicativo mobile e suas
dependências de execução. Desktop, SQL Server, funções do Supabase, testes e
ferramentas de desenvolvimento não precisam ser copiados para o celular.

## Gerar um APK otimizado

Na raiz do projeto, com Flutter e Android SDK configurados:

```powershell
# Instalar as dependências se este for um checkout novo:
Push-Location mobile
flutter pub get
Pop-Location

# Preencher mobile/config.json conforme mobile/config.example.json.
# Usar a URL e a chave pública do Supabase; nunca service_role.
./mobile/scripts/build-release.ps1 -BuildNumber 2007
```

O script usa o Flutter de `.local/flutter` quando disponível; caso contrário,
usa o Flutter do PATH. Ele compila o código atual em modo `release`, com login
cloud, otimização de código e recursos e apenas uma arquitetura por APK.
A câmera e o modelo de leitura de códigos continuam incluídos. A separação por
ABI também remove bibliotecas de plugins para outras arquiteturas. O argumento
`force-version-code-ignoring-abi=true` mantém o número informado em `BuildNumber`,
sem o acréscimo automático por arquitetura do Flutter.

Saída padrão: `mobile/build/releases/Lineboard-2007-arm64.apk`.
ARM64 corresponde à arquitetura da cópia anterior do APK guardada neste projeto.
Para outro aparelho, confira a arquitetura antes de escolher:

```powershell
./mobile/scripts/build-release.ps1 -BuildNumber 2008 -TargetPlatform android-arm
```

`android-arm` gera ARM de 32 bits; `android-x64` atende dispositivos/emuladores x64.
Use um `BuildNumber` maior que o instalado nas próximas atualizações. O script
não sobrescreve um APK já arquivado com o mesmo número e arquitetura.

O build mantém o pacote `io.lineboard.lineboard_mobile` e a configuração atual
de assinatura com a chave de debug da máquina. É um APK com código otimizado
para instalação direta; a assinatura de produção para distribuição em loja
ainda precisa ser configurada. Atualizar sobre um aplicativo existente exige
a mesma chave de assinatura.

## Validação

```powershell
cd mobile
flutter analyze
flutter test
```

O APK não inclui o servidor. Login, sincronização e fotos dependem dos serviços
configurados e das funções/migrations correspondentes no Supabase. Compilar não
publica esses serviços. Câmera, leitura de etiqueta real e atualização sobre uma
instalação existente também precisam ser conferidas no aparelho.
