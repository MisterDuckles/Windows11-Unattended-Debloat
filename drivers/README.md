# drivers\

Alles wat hier staat gaat de gebouwde ISO in en wordt tijdens Windows Setup geladen. Doel:
**je touchpad laten werken op het partitiescherm**, voordat Windows geinstalleerd is.

## Je hoeft hier meestal niets neer te zetten

`build-helper.ps1` vraagt bij het bouwen of het de touchpad-drivers moet ophalen:

```
[2b/5] Touchpad-drivers voor Windows Setup...
    Touchpad-drivers ophalen en meebakken? (J/n)
```

Enter = ja. Het script haalt dan per Intel-generatie het Serial IO-pakket (I2C + GPIO + SPI +
UART) van de Microsoft Update Catalog en zet het in `drivers\IntelSerialIO\<generatie>_<versie>\`.
Acht pakketten, samen zo'n 2 MB, ongeveer een halve minuut. Daarna volgen ze dezelfde route als
alles wat je hier handmatig neerzet. Zonder vraag: `-TouchpadDrivers Download` of `-TouchpadDrivers Skip`.

Eenmaal opgehaalde pakketten blijven staan en worden hergebruikt; bij een nieuwere versie in de
catalog wordt de oude map vervangen. Wil je ze kwijt, verwijder dan `IntelSerialIO\`.

## Waarom dit nodig is

Windows Setup draait in WinPE, en WinPE heeft alleen de drivers die in `boot.wim` zitten. Een
moderne precisie-touchpad hangt niet aan PS/2 of USB maar aan de I2C-bus van het moederbord,
dus je hebt drie lagen nodig: de GPIO-controller (interrupt), de I2C-controller (bus) en
`hidi2c` (het HID-apparaat zelf).

`hidi2c` zit in de box. De controllers lang niet altijd. Nagemeten op Windows 11 25H2
(build 26200):

| Platform                              | In-box driver in boot.wim? |
|---------------------------------------|----------------------------|
| AMD (ACPI\AMDI0010 / AMDI0030)        | ja - `amdi2c.inf`, `amdgpio2.inf` |
| Intel t/m Comet Lake / Gemini Lake    | ja - `iaLPSS2i_*_SKL/BXT_P/CNL/GLK.inf` |
| Intel Ice Lake (2019) en alles daarna | **nee** - dit is wat de catalog-download oplost |

Op het geinstalleerde Windows valt het niet op, want daar levert Windows Update ze alsnog -
maar tijdens setup is er geen Windows Update.

## Handmatig iets toevoegen

Voor alles wat de catalog-route niet dekt: een storage-driver (Intel RST/VMD) als je schijf niet
zichtbaar is in setup, een touchpad-driver van een exotisch model, een netwerkkaart.

Uitgepakte drivers: mappen met `.inf`, `.sys` en `.cat` erin. Geen `.exe`-installers, geen
zip-bestanden - DISM kan daar niets mee. Submappen mogen; er wordt recursief gezocht.

```
drivers\
  IntelSerialIO\            <- vult build-helper.ps1 zelf
    TigerLake_30.100.2129.8\
    ...
  IntelRST\                 <- zelf neergezet
    iaStorVD.inf
    iaStorVD.sys
    iaStorVD.cat
```

Bouw je de ISO op een machine van dezelfde generatie als de doel-laptop, dan exporteert
`.\build-helper.ps1 -HarvestInputDrivers` de invoerdrivers van de buildmachine en neemt die mee.
Alleen zinvol bij vergelijkbare hardware: een AMD-laptop levert geen Intel-driver op.

## Wat build-helper.ps1 ermee doet

1. **Injecteert alles in `boot.wim`** (het Setup-image, index 2) met DISM. Dit is wat het
   touchpad op het partitiescherm laat werken: WinPE laadt die drivers bij het opstarten.
2. **Kopieert alles naar `$WinPEDriver$` in de ISO-root.** Setup scant die map op elke
   schijfletter vanaf C: en zet de drivers ook klaar voor het geinstalleerde Windows.

Beide routes krijgen dezelfde bestanden, met opzet. Microsoft KB2686316 waarschuwt dat je nooit
twee **verschillende versies** van dezelfde driver via die twee routes moet aanbieden: de versie
die WinPE al in het geheugen heeft wint, en de andere wordt als "bad driver" gemarkeerd en
daarna genegeerd - ook als die nieuwer is. Om dezelfde reden haalt de catalog-route INF's voor
in-box generaties uit een gedownload pakket (het Ice Lake-pakket bevat bv. ook Skylake-INF's).

Drivers moeten ondertekend zijn. Zo niet, dan slaat DISM ze over en meldt build-helper dat; het
eindoverzicht toont het aantal pakketten dat **na** de injectie echt in `boot.wim` zit.

## Git

De inhoud van deze map staat in `.gitignore`. Driverpakketten zijn groot, binair en van derden;
die horen niet in deze repo. Alleen dit bestand wordt bijgehouden.
