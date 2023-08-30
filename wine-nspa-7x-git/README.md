## Wine-NSPA

Wine-NSPA uses Wine-tkg, which is a build-system aiming at easier custom wine builds creation.

## How-to:

(for dependencies, see Wine-Tkg's [wiki page](https://github.com/Tk-Glitch/PKGBUILDS/wiki/wine-tkg-git) )

## Building:

 * We need to get into the wine-tkg-git dir first:
```
cd wine-tkg-git
```

### For Arch (and other pacman/makepkg distros) :

 * From the `wine-tkg-git` directory (where the PKGBUILD is located), run the following command in a terminal to start the building process :
```
makepkg -si
```

### For other distros (make sure to check the [wiki page](https://github.com/Tk-Glitch/PKGBUILDS/wiki/wine-tkg-git)) :

 * From the `wine-tkg-git` directory (where the PKGBUILD is located), run the following command in a terminal to start the building process :
```
./non-makepkg-build.sh
```
**Your build will be found in the `PKGBUILD/wine-tkg-git/non-makepkg-builds` dir (independently of the chosen configuration)**
