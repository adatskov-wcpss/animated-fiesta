/* Selkies Forge - distro marks and desktop glyphs.
   Hand-drawn simplified shapes so the UI needs no network and no icon font. */
(function () {
  "use strict";

  var L = {};

  L.ubuntu = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16" fill="none" stroke="#E95420" stroke-width="3.4" stroke-dasharray="20 9" stroke-linecap="round" transform="rotate(-18 24 24)"/><circle cx="24" cy="7.6" r="4.6" fill="#E95420"/><circle cx="9.7" cy="32.2" r="4.6" fill="#E95420"/><circle cx="38.3" cy="32.2" r="4.6" fill="#E95420"/><circle cx="24" cy="24" r="4.1" fill="#E95420" opacity=".55"/></svg>';

  L.debian = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M31 11.5a15 15 0 1 0 5.4 17.8" fill="none" stroke="#D70A53" stroke-width="3.2" stroke-linecap="round"/><path d="M28.8 17.6a9.2 9.2 0 1 0 3.1 10.7" fill="none" stroke="#D70A53" stroke-width="3" stroke-linecap="round"/><circle cx="24.6" cy="24.4" r="3.1" fill="#D70A53"/></svg>';

  L.fedora = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16.5" fill="#51A2DA"/><path d="M28.6 13.6h-3.9a5.9 5.9 0 0 0-5.9 5.9v3.4h-3.2v5.4h3.2v6.1h5.6v-6.1h4.1v-5.4h-4.1v-2.6c0-.9.7-1.6 1.6-1.6h2.6z" fill="#fff"/></svg>';

  L.arch = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 6 7 40l17-9 17 9z" fill="none" stroke="#1793D1" stroke-width="3.2" stroke-linejoin="round"/><path d="M24 14.5 16.5 31 24 27.2 31.5 31z" fill="#1793D1" opacity=".5"/></svg>';

  L.alpine = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="6" width="36" height="36" rx="7" fill="#0D597F"/><path d="M12 33 20 20l5.5 9 2.6-4.2L36 33z" fill="#fff"/><path d="M20 20l5.5 9h-11z" fill="#9ad7f2"/></svg>';

  L.kali = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="17" fill="#0b1120" stroke="#367BF0" stroke-width="2"/><path d="M14 13v22M14 24l10-9M14 25l11 10" fill="none" stroke="#367BF0" stroke-width="3" stroke-linecap="round"/><path d="M28 14c7 2 10 6 10 11s-4 8-8 9c4-3 5-6 4-9s-3-6-6-11z" fill="#367BF0" opacity=".75"/></svg>';

  L.parrot = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M30 9c-8 0-14 6-14 14 0 6 3 9 3 13 0 2-2 3-4 3h18c5 0 9-5 9-12 0-10-5-18-12-18z" fill="#15E0C8"/><circle cx="31" cy="19" r="2.4" fill="#06262b"/><path d="M16 21l-7 4 7 3z" fill="#0fae9b"/></svg>';

  L.almalinux = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 7 10 41h6.4l7.6-19 7.6 19H38z" fill="#0F4266"/><path d="M17 29h14l2.4 6H14.6z" fill="#49C96D"/><circle cx="24" cy="12" r="3.4" fill="#FFD042"/></svg>';

  L.rocky = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16.5" fill="none" stroke="#10B981" stroke-width="2.4"/><path d="M13 31 25 15l11 15z" fill="#10B981"/><path d="M25 15l-5.5 8h11z" fill="#6ee7b7"/></svg>';

  L.oracle = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="15" width="36" height="18" rx="9" fill="none" stroke="#C74634" stroke-width="4.2"/></svg>';

  L.centos = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 7v12M24 29v12M7 24h12M29 24h12" stroke-width="5" stroke-linecap="round" fill="none" stroke="#932279"/><path d="M24 7v12" stroke="#932279" stroke-width="5" stroke-linecap="round"/><path d="M7 24h12" stroke="#EFA724" stroke-width="5" stroke-linecap="round"/><path d="M24 29v12" stroke="#79A031" stroke-width="5" stroke-linecap="round"/><path d="M29 24h12" stroke="#262577" stroke-width="5" stroke-linecap="round"/><circle cx="24" cy="24" r="4.2" fill="#fff" opacity=".85"/></svg>';

  L.opensuse = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16" fill="#73BA25"/><circle cx="18.5" cy="19.5" r="3" fill="#fff"/><circle cx="18.5" cy="19.5" r="1.3" fill="#2d4a0c"/><path d="M30 17c4 3 5 8 3 12-2 3-6 4-9 3 5-1 7-4 7-8 0-3-1-5-1-7z" fill="#fff" opacity=".85"/></svg>';

  L.remnux = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 6l14 8v20l-14 8-14-8V14z" fill="#5B3FA8"/><circle cx="22" cy="22" r="6.5" fill="none" stroke="#fff" stroke-width="2.6"/><path d="M27 27l6 6" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>';

  L.mint = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="9" width="36" height="30" rx="5" fill="#86BE43"/><path d="M13 31V20c0-3 2-5 5-5 2.4 0 3.6 1.2 4.4 2.6.8-1.4 2-2.6 4.4-2.6 3 0 5 2 5 5v11h-4.4V21c0-1-.6-1.6-1.6-1.6s-1.6.6-1.6 1.6v10h-4.4V21c0-1-.6-1.6-1.6-1.6S16 20 16 21v10z" fill="#fff"/></svg>';

  L.zorin = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16.5" fill="none" stroke="#1792D3" stroke-width="3"/><path d="M15 17h18L15 31h18" fill="none" stroke="#1792D3" stroke-width="3.2" stroke-linejoin="round" stroke-linecap="round"/></svg>';

  L.pop = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M10 38V12h9a8 8 0 0 1 0 16h-9" fill="none" stroke="#48B9C7" stroke-width="4" stroke-linecap="round"/><path d="M30 16h8v8" fill="none" stroke="#FFB13D" stroke-width="4" stroke-linecap="round"/><path d="M38 32h-8" fill="none" stroke="#FFB13D" stroke-width="4" stroke-linecap="round"/></svg>';

  L.elementary = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16.5" fill="#64BAFF"/><path d="M31 27a8 8 0 1 1-1-8H17v4h12" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>';

  L.garuda = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 8c6 6 14 8 14 16s-6 14-14 16c-8-2-14-8-14-16S18 14 24 8z" fill="none" stroke="#D81E5B" stroke-width="2.6"/><path d="M24 14c3 4 8 6 8 11s-4 8-8 10c-4-2-8-5-8-10s5-7 8-11z" fill="#D81E5B" opacity=".8"/></svg>';

  L["generic-mac"] = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="10" width="36" height="26" rx="5" fill="none" stroke="#9fb3d9" stroke-width="2.4"/><path d="M6 17h36" stroke="#9fb3d9" stroke-width="2"/><circle cx="11.5" cy="13.5" r="1.5" fill="#9fb3d9"/><circle cx="16.5" cy="13.5" r="1.5" fill="#9fb3d9"/><circle cx="21.5" cy="13.5" r="1.5" fill="#9fb3d9"/><rect x="16" y="38" width="16" height="2.6" rx="1.3" fill="#9fb3d9"/></svg>';

  L["generic-win"] = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="9" width="36" height="24" rx="3" fill="none" stroke="#7fb0f0" stroke-width="2.4"/><path d="M6 15h36" stroke="#7fb0f0" stroke-width="2"/><rect x="6" y="36" width="36" height="6" rx="2" fill="#7fb0f0" opacity=".55"/><rect x="9" y="37.6" width="7" height="2.8" rx="1.4" fill="#0b1120"/></svg>';

  L.generic = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16" fill="none" stroke="currentColor" stroke-width="2.4" opacity=".8"/><circle cx="24" cy="19" r="5" fill="currentColor" opacity=".8"/><path d="M14 36c2-5 5.5-7.5 10-7.5S32 31 34 36z" fill="currentColor" opacity=".8"/></svg>';

  /* ---------------------------------------------------------------- *
   * Desktop glyphs: layout marks, not brand logos.  Each one shows
   * roughly how that desktop arranges the screen.
   * ---------------------------------------------------------------- */
  var F = 'fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"';
  function frame(inner) {
    return '<svg viewBox="0 0 32 24" aria-hidden="true"><rect x="1" y="1" width="30" height="22" rx="2.5" ' +
      F + ' opacity=".55"/>' + inner + '</svg>';
  }
  var G = {};
  G.xfce = frame('<rect x="3" y="3" width="26" height="3" rx="1.2" fill="currentColor" opacity=".8"/><rect x="5" y="9" width="11" height="10" rx="1.6" ' + F + '/><rect x="18" y="12" width="9" height="7" rx="1.6" ' + F + '/>');
  G.mate = frame('<rect x="3" y="3" width="26" height="2.6" rx="1.2" fill="currentColor" opacity=".8"/><rect x="3" y="18.4" width="26" height="2.6" rx="1.2" fill="currentColor" opacity=".8"/><rect x="8" y="8" width="16" height="8" rx="1.6" ' + F + '/>');
  G.kde = frame('<rect x="3" y="18" width="26" height="3" rx="1.4" fill="currentColor" opacity=".8"/><rect x="5" y="4" width="13" height="11" rx="1.6" ' + F + '/><rect x="20" y="7" width="7" height="8" rx="1.6" ' + F + '/><circle cx="6.4" cy="19.5" r="1" fill="#0b1120"/>');
  G.lxqt = frame('<rect x="3" y="19" width="26" height="2.4" rx="1.2" fill="currentColor" opacity=".8"/><rect x="6" y="5" width="20" height="11" rx="1.6" ' + F + '/>');
  G.lxde = G.lxqt;
  G.lumina = G.lxqt;
  G.cinnamon = frame('<rect x="3" y="18" width="26" height="3" rx="1.4" fill="currentColor" opacity=".8"/><rect x="4" y="18.6" width="4" height="1.8" rx=".9" fill="#0b1120"/><rect x="5" y="4" width="22" height="11" rx="1.8" ' + F + '/>');
  G.budgie = frame('<rect x="22" y="3" width="7" height="18" rx="2" fill="currentColor" opacity=".75"/><rect x="4" y="5" width="15" height="14" rx="1.8" ' + F + '/>');
  G.gnome = frame('<rect x="3" y="3" width="26" height="3" rx="1.4" fill="currentColor" opacity=".8"/><circle cx="12" cy="14" r="1.5" fill="currentColor"/><circle cx="16.5" cy="14" r="1.5" fill="currentColor"/><circle cx="21" cy="14" r="1.5" fill="currentColor"/>');
  G.ukui = G.cinnamon;
  G.enlightenment = frame('<path d="M22 7a7.5 7.5 0 1 0 2 9.5" ' + F + '/><circle cx="16" cy="12" r="2.4" fill="currentColor" opacity=".8"/>');
  G.i3 = frame('<rect x="4" y="4" width="11" height="16" rx="1.4" ' + F + '/><rect x="17" y="4" width="11" height="7.5" rx="1.4" ' + F + '/><rect x="17" y="12.5" width="11" height="7.5" rx="1.4" ' + F + '/>');
  G.bspwm = frame('<rect x="4" y="4" width="13" height="16" rx="1.4" ' + F + '/><rect x="19" y="4" width="9" height="16" rx="1.4" ' + F + '/><path d="M19 12h9" stroke="currentColor" stroke-width="1.7"/>');
  G.herbstluftwm = frame('<rect x="4" y="4" width="24" height="7" rx="1.4" ' + F + '/><rect x="4" y="13" width="11" height="7" rx="1.4" ' + F + '/><rect x="17" y="13" width="11" height="7" rx="1.4" ' + F + '/>');
  G.qtile = frame('<rect x="4" y="4" width="8" height="16" rx="1.4" ' + F + '/><rect x="14" y="4" width="14" height="10" rx="1.4" ' + F + '/><rect x="14" y="16" width="14" height="4" rx="1.4" ' + F + '/>');
  G.xmonad = frame('<rect x="4" y="4" width="15" height="16" rx="1.4" ' + F + '/><rect x="21" y="4" width="7" height="5" rx="1.2" ' + F + '/><rect x="21" y="11" width="7" height="4" rx="1.2" ' + F + '/><rect x="21" y="17" width="7" height="3" rx="1.2" ' + F + '/>');
  G.awesome = frame('<rect x="3" y="3" width="26" height="2.6" rx="1.2" fill="currentColor" opacity=".8"/><rect x="4" y="8" width="12" height="12" rx="1.4" ' + F + '/><rect x="18" y="8" width="10" height="12" rx="1.4" ' + F + '/>');
  G.spectrwm = G.i3;
  G.dwm = frame('<rect x="3" y="3" width="26" height="2.4" rx="1.1" fill="currentColor" opacity=".8"/><rect x="4" y="8" width="16" height="12" rx="1.2" ' + F + '/><rect x="22" y="8" width="6" height="12" rx="1.2" ' + F + '/>');
  G.cwm = frame('<rect x="6" y="6" width="14" height="10" rx="1.4" ' + F + '/><rect x="13" y="11" width="14" height="9" rx="1.4" ' + F + '/>');
  G.ratpoison = frame('<rect x="4" y="4" width="24" height="16" rx="1.4" ' + F + '/>');
  G.openbox = frame('<rect x="5" y="5" width="14" height="10" rx="1.4" ' + F + '/><rect x="14" y="10" width="13" height="9" rx="1.4" ' + F + '/><rect x="3" y="19" width="26" height="2" rx="1" fill="currentColor" opacity=".7"/>');
  G.fluxbox = frame('<rect x="4" y="4" width="24" height="3" rx="1.2" fill="currentColor" opacity=".75"/><rect x="6" y="9" width="12" height="9" rx="1.4" ' + F + '/><rect x="19" y="9" width="8" height="9" rx="1.4" ' + F + '/>');
  G.icewm = frame('<rect x="3" y="18.4" width="26" height="2.8" rx="1.3" fill="currentColor" opacity=".8"/><rect x="5" y="4" width="22" height="12" rx="1.4" ' + F + '/><rect x="5" y="4" width="22" height="3" rx="1.4" fill="currentColor" opacity=".55"/>');
  G.jwm = G.icewm;
  G.pekwm = G.fluxbox;
  G.wmaker = frame('<rect x="22" y="3" width="6" height="6" rx="1.3" fill="currentColor" opacity=".8"/><rect x="22" y="11" width="6" height="6" rx="1.3" fill="currentColor" opacity=".55"/><rect x="4" y="5" width="15" height="14" rx="1.6" ' + F + '/>');
  G.fvwm = G.cwm;
  G.twm = frame('<rect x="6" y="7" width="20" height="11" rx="1" ' + F + '/><path d="M6 10h20" stroke="currentColor" stroke-width="1.7"/>');
  G.generic = G.openbox;

  window.FORGE_LOGOS = L;
  window.FORGE_GLYPHS = G;
  /* Real marks (brands.js, from Simple Icons) win; the hand-drawn ones above
     cover families Simple Icons does not carry, and anything offline. */
  window.forgeLogo = function (family) {
    var B = window.FORGE_BRANDS || {};
    return B[family] || L[family] || L.generic;
  };
  window.forgeGlyph = function (glyph) { return G[glyph] || G.generic; };
})();
