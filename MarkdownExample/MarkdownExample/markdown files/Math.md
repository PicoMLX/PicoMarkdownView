# Math

Explore native typesetting in paragraphs, lists, tables, and displayed equations. The named equation examples below come from the pinned SwiftMath example collection, with explanatory prose added for this showcase.

## Math in a document

A measurement $x_i$ can appear inside an ordinary sentence. The mean \(\mu\) and standard deviation $\sigma$ retain their mathematical appearance alongside **bold**, *italic*, and `code` text.

Both `$...$` and `\(...\)` delimit inline math. The displayed examples below also use both `$$...$$` and `\[...\]` delimiters.

### A short analysis workflow

1. Collect the observations \(x_1, x_2, \ldots, x_N\).
2. Compute their mean, $\mu = \frac{1}{N}\sum_{i=1}^{N}x_i$.
3. Compare each residual \(x_i-\mu\) with the spread $\sigma$.

### Notation alongside prose

| Quantity | Inline math | Meaning |
| :--- | :---: | :--- |
| Observation | \(x_i\) | The value of sample $i$ |
| Mean | $\mu = \frac{1}{N}\sum_{i=1}^{N}x_i$ | The center of the measurements |
| Variance | \(\sigma^2\) | The squared spread |
| Standard deviation | $\sqrt{\sigma^2}$ | Spread in the original units |

> **Reading tip:** The notation \(x_i\) describes one sample; $\{x_1,\ldots,x_N\}$ describes the collection. Selection can cross this quote, the table, and the equations below.

## Equation collection

### Square of sums

An inline expression stays in the surrounding paragraph while keeping its own subscripts and superscripts.

Within a sentence: \((a_1 + a_2)^2 = a_1^2 + 2a_1a_2 + a_2^2\).

### Quadratic Formula

A displayed fraction gives the numerator, square root, and denominator room to align.

$$
x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}
$$

### Standard Deviation

Nested fractions, a summation, and a radical combine in one expression.

\[
\sigma = \sqrt{\frac{1}{N}\sum_{i=1}^N (x_i - \mu)^2}
\]

### De Morgan's laws

Logical operators can appear inline alongside ordinary explanatory text.

Within a sentence: $\neg(P\land Q) \iff (\neg P)\lor(\neg Q)$.

### Log Change of Base

An inline fraction is useful when discussing a short identity within a sentence.

Within a sentence: $\log_b(x) = \frac{\log_a(x)}{\log_a(b)}$.

### Cosine addition

Greek letters, function names, and parentheses share one baseline.

$$
\cos(\theta + \varphi) = \cos(\theta)\cos(\varphi) - \sin(\theta)\sin(\varphi)
$$

### Limit e^k

A limit annotation sits below the operator in display style, with automatically sized delimiters.

\[
\lim_{x\to\infty}\left(1 + \frac{k}{x}\right)^x = e^k
\]

### Calculus

An integral combines infinite bounds, an accented function, a complex exponential, and upright differential notation.

$$
f(x) = \int\limits_{-\infty}^\infty\hat f(\xi)\,e^{2 \pi i \xi x}\,\mathrm{d}\xi
$$

### Stirling Numbers of the Second Kind

A combinatorial identity mixes a brace construction, a factorial, a sum, and a binomial coefficient.

\[
{n \brace k} = \frac{1}{k!}\sum_{j=0}^k (-1)^{k-j}\binom{k}{j}(k-j)^n
\]

### Gaussian Integral

Spacing commands keep the integral and its exponential integrand readable.

$$
\int_{-\infty}^{\infty} \! e^{-x^2} dx = \sqrt{\pi}
$$

### Arithmetic mean, geometric mean inequality

An indexed root and a product compare two different kinds of mean.

\[
\frac{1}{n}\sum_{i=1}^{n}x_i \geq \sqrt[n]{\prod_{i=1}^{n}x_i}
\]

### Cauchy-Schwarz inequality

Large parentheses contain sums on both sides of an inequality.

$$
\left(\sum_{k=1}^n a_k b_k \right)^2 \le \left(\sum_{k=1}^n a_k^2\right)\left(\sum_{k=1}^n b_k^2\right)
$$

### Cauchy integral formula

A contour integral uses a closed integral sign, subscripts, derivatives, and a complex denominator.

\[
f^{(n)}(z_0) = \frac{n!}{2\pi i}\oint_\gamma\frac{f(z)}{(z-z_0)^{n+1}}dz
\]

### Schroedinger's Equation

The time-dependent wave equation combines differential operators, vector notation, and a potential term.

$$
i\hbar\frac{\partial}{\partial t}\mathbf\Psi(\mathbf{x},t) = -\frac{\hbar}{2m}\nabla^2\mathbf\Psi(\mathbf{x},t)
+ V(\mathbf{x})\mathbf\Psi(\mathbf{x},t)
$$

### Lorentz Equations

A gathered environment centers a short system of equations on separate lines.

\[
\begin{gather}
\dot{x} = \sigma(y-x) \\
\dot{y} = \rho x - y - xz \\
\dot{z} = -\beta z + xy
\end{gather}
\]

### Cross product

A determinant lays out unit vectors and partial derivatives in aligned columns.

$$
\vec \bf V_1 \times \vec \bf V_2 =  \begin{vmatrix}
\hat \imath &\hat \jmath &\hat k \\
\frac{\partial X}{\partial u} & \frac{\partial Y}{\partial u} & 0 \\
\frac{\partial X}{\partial v} & \frac{\partial Y}{\partial v} & 0
\end{vmatrix}
$$

### Maxwell's Equations

An aligned environment lines up a system of vector equations at their equals signs.

\[
\begin{eqalign}
\nabla \cdot \vec{\bf E} & = \frac {\rho} {\varepsilon_0} \\
\nabla \cdot \vec{\bf B} & = 0 \\
\nabla \times \vec{\bf E} &= - \frac{\partial\vec{\bf B}}{\partial t} \\
\nabla \times \vec{\bf B} & = \mu_0\vec{\bf J} + \mu_0\varepsilon_0 \frac{\partial\vec{\bf E}}{\partial t}
\end{eqalign}
\]

### Matrix multiplication

Multiple parenthesized matrices show both layout and multiplication in a single display.

$$
\begin{pmatrix}
a & b\\ c & d
\end{pmatrix}
\begin{pmatrix}
\alpha & \beta \\ \gamma & \delta
\end{pmatrix} =
\begin{pmatrix}
a\alpha + b\gamma & a\beta + b \delta \\
c\alpha + d\gamma & c\beta + d \delta
\end{pmatrix}
$$

### Cases

A cases environment groups a piecewise definition behind one brace.

\[
f(x) = \begin{cases}
\frac{e^x}{2} & x \geq 0 \\
1 & x < 0
\end{cases}
\]

### Splitting long equations

An explicit line break and indentation continue an expression across lines.

$$
\frak Q(\lambda,\hat{\lambda}) =
-\frac{1}{2} \mathbb P(O \mid \lambda ) \sum_s \sum_m \sum_t \gamma_m^{(s)} (t) +\\
\quad \left( \log(2 \pi ) + \log \left| \cal C_m^{(s)} \right| +
\left( o_t - \hat{\mu}_m^{(s)} \right) ^T \cal C_m^{(s)-1} \right)
$$

Equation source: [SwiftMath 1.7.3 examples](https://github.com/mgriebling/SwiftMath/blob/fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7/EXAMPLES.md), used under the MIT license. The Lorentz example's stray terminal quote is removed; other equation bodies are unchanged apart from trailing whitespace. Prose, table, lists, and Markdown composition are PicoMarkdownView additions.
