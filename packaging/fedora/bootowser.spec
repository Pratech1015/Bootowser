%global debug_package %{nil}

Name:           bootowser
Version:        0.1.0
Release:        1%{?dist}
Summary:        Stripped Chromium kiosk browser with a Plymouth boot splash

License:        GPL-3.0-or-later
URL:            https://github.com/Pratech1015/Bootowser
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  systemd-devel
Requires:       systemd-libs
Requires:       xorg-server
Recommends:     plymouth
Recommends:     xorg-x11-utils
Suggests:       mesa-dri-drivers

%description
Bootowser replaces the boot splash with a real web browser. It is a
stripped-down Chromium build -- no tabs, no omnibox, no settings, no
extensions, no telemetry -- that starts automatically at boot and shows a
single fullscreen page.

It is aimed at single-purpose devices: signage, information kiosks, menu
boards and TV-style displays where a full desktop environment is more than
the device needs.

%package systemd
Summary:        Systemd units for %{name}
BuildArch:      noarch

%description systemd
The systemd units that start the display server and the kiosk browser at boot.

# The browser binary is a separately built Chromium; see the browser/ directory
# in the upstream repository. Fail loudly rather than shipping a package with
# no browser in it.
%global browserbin %{_libdir}/bootowser/chrome

%prep
%autosetup

%build
browser="$(find "%{_sourcedir}" -maxdepth 4 -type f -path '*/out/*/chrome' -perm -u+x | head -n1)"
if [ -z "$browser" ]; then
  browser="$(find "%{_sourcedir}" -maxdepth 4 -type f -name chrome -perm -u+x | head -n1)"
fi
if [ -z "$browser" ]; then
  # Allow an externally built binary too.
  if [ -n "$BOOTOWSER_BROWSER" ] && [ -x "$BOOTOWSER_BROWSER" ]; then
    browser="$BOOTOWSER_BROWSER"
  fi
fi
if [ -z "$browser" ]; then
  echo "error: no Bootowser browser binary found in the source tree" >&2
  echo "       Build it first:  cd browser && ./fetch.sh && ./build.sh" >&2
  exit 1
fi
echo "using browser binary: $browser"

bdir="$(dirname "$(readlink -f "$browser")")"

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}%{_prefix}/lib/bootowser
mkdir -p %{buildroot}%{_datadir}/bootowser
mkdir -p %{buildroot}%{_datadir}/plymouth/themes/theme.bootowser
mkdir -p %{buildroot}%{_sysconfdir}/bootowser/policies/managed
mkdir -p %{buildroot}%{_docdir}/bootowser
mkdir -p %{buildroot}%{_unitdir}
mkdir -p %{buildroot}%{_localstatedir}/lib/bootowser/profile

install -p -m 0755 runtime/bin/bootowser          %{buildroot}%{_prefix}/lib/bootowser/bootowser
install -p -m 0755 runtime/bin/bootowser-xsession %{buildroot}%{_prefix}/lib/bootowser/bootowser-xsession
install -p -m 0644 runtime/xorg/xorg.conf         %{buildroot}%{_datadir}/bootowser/xorg.conf

install -p -m 0644 runtime/lib/systemd/system/bootowser.service          %{buildroot}%{_unitdir}/bootowser.service
install -p -m 0644 runtime/lib/systemd/system/bootowser-xserver.service %{buildroot}%{_unitdir}/bootowser-xserver.service

for f in plymouth/theme.bootowser/*; do
  install -p -m 0644 "$f" %{buildroot}%{_datadir}/plymouth/themes/theme.bootowser/$(basename "$f")
done

install -p -m 0644 runtime/etc/bootowser/bootowser.conf \
                 %{buildroot}%{_sysconfdir}/bootowser/bootowser.conf
install -p -m 0644 runtime/etc/bootowser/policies/managed/bootowser.json \
                 %{buildroot}%{_sysconfdir}/bootowser/policies/managed/bootowser.json

# The browser plus the data it cannot start without.
install -p -m 0755 "$browser" %{buildroot}%{_prefix}/lib/bootowser/chrome
[ -f "$bdir/icudtl.dat" ] && install -p -m 0644 "$bdir/icudtl.dat" %{buildroot}%{_prefix}/lib/bootowser/
for f in "$bdir"/*.pak "$bdir"/*.bin; do
  [ -f "$f" ] && install -p -m 0644 "$f" %{buildroot}%{_prefix}/lib/bootowser/
done
for d in locales swiftshader; do
  [ -d "$bdir/$d" ] && cp -a "$bdir/$d" %{buildroot}%{_prefix}/lib/bootowser/
done
if [ -f "$bdir/chrome_sandbox" ]; then
  install -p -m 4755 "$bdir/chrome_sandbox" %{buildroot}%{_prefix}/lib/bootowser/chrome_sandbox
fi

install -p -m 0644 LICENSE  %{buildroot}%{_docdir}/bootowser/COPYING
install -p -m 0644 README.md %{buildroot}%{_docdir}/bootowser/README.md
install -p -m 0644 docs/security.md %{buildroot}%{_docdir}/bootowser/security.md

%pre
getent group bootowser >/dev/null || groupadd -r bootowser
getent passwd bootowser >/dev/null || \
  useradd -r -g bootowser -d /var/lib/bootowser -s /sbin/nologin \
          -c "Bootowser kiosk browser" bootowser
usermod -a -G video,render bootowser >/dev/null 2>&1 || :

%post systemd
%systemd_post bootowser-xserver.service
%systemd_post bootowser.service

%preun systemd
%systemd_preun bootowser-xserver.service
%systemd_preun bootowser.service

%postun systemd
%systemd_postun_with_restart bootowser.service

%files
%license LICENSE
%doc %{_docdir}/bootowser/README.md
%doc %{_docdir}/bootowser/security.md
%{_prefix}/lib/bootowser/bootowser
%{_prefix}/lib/bootowser/bootowser-xsession
%{_prefix}/lib/bootowser/chrome
%{_prefix}/lib/bootowser/chrome_sandbox
%{_prefix}/lib/bootowser/*.pak
%{_prefix}/lib/bootowser/*.bin
%{_prefix}/lib/bootowser/icudtl.dat
%{_datadir}/bootowser/xorg.conf
%{_datadir}/plymouth/themes/theme.bootowser
%config(noreplace) %{_sysconfdir}/bootowser/bootowser.conf
%config(noreplace) %{_sysconfdir}/bootowser/policies/managed/bootowser.json
%attr(0700,bootowser,bootowser) %dir %{_localstatedir}/lib/bootowser/profile

%files systemd
%{_unitdir}/bootowser.service
%{_unitdir}/bootowser-xserver.service

%changelog
* Wed Sep 30 2026 Pratech1015 <pragyan.krish3@gmail.com> - 0.1.0-1
- Initial release: stripped Chromium kiosk browser runtime, systemd units,
  minimal X server configuration and the theme.bootowser Plymouth splash.