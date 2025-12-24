import Alpine from 'alpinejs';
import './style.css';
import { tacticsApp } from './app';
import { Chess } from './chess';

window.Chess = Chess;
window.Alpine = Alpine;

Alpine.data('tacticsApp', tacticsApp);
Alpine.start();

